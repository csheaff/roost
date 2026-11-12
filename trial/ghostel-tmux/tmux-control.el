;;; tmux-control.el --- Trial: what Roost calls of tmux-control, on ghostel-tmux  -*- lexical-binding: t; -*-

;; Version: 99.0
;; Package-Requires: ((emacs "30.1") (ghostel "0.64.0") (ghostel-tmux "0.2.0"))

;;; Commentary:

;; A trial, not for release.  Roost reaches its terminals through about
;; twenty functions, two hooks and one mode of tmux-control.  This file
;; gives them the same names on top of ghostel-tmux, so that Roost runs
;; unchanged with this directory on the load path in place of
;; tmux-control's:
;;
;;   emacs -L trial/ghostel-tmux -L <ghostel>/lisp -L <ghostel-tmux> ...
;;
;; Each definition says what it needed of ghostel-tmux that is not public
;; there, marked NEEDS.  Those notes are the point of the trial: they are
;; what a move of Roost to ghostel-tmux would ask of it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ghostel)
(require 'ghostel-tmux)

(defgroup tmux-control nil
  "Trial stand-in for tmux-control on ghostel-tmux."
  :group 'terminals)

(defconst tmux-control-version "99.0"
  "A version above any Roost asks for.")

(defcustom tmux-control-default-socket-name "main"
  "Default tmux socket name."
  :type 'string)

(defvar tmux-control-ssh-options nil
  "Unused here: ghostel-tmux reaches a remote host through TRAMP.")

(defvar tmux-control-remote-tmux-socket-setup
  "fs=$(stat -f -c %T \"$HOME\" 2>/dev/null); case \"$fs\" in nfs|nfs4|lustre|gpfs|cifs|smb*|afs) d=\"/tmp/tmux-$(id -u)-sock\";; *) d=\"$HOME/.tmux-sock\";; esac; mkdir -p \"$d\" && chmod 700 \"$d\" && export TMUX_TMPDIR=\"$d\""
  "Shell snippet run before tmux on a remote host, as tmux-control has it.
Roost's helper runs it too, so both find the same tmux server.")

(defvar tmux-control-session-activity nil
  "Unused here: ghostel-tmux names no other session's activity.")

(defvar tmux-control-switch-session-functions nil
  "Never run here: ghostel-tmux has no command that switches session.")

(defvar tmux-control-window-buffer-functions nil
  "Functions called with each pane buffer ghostel-tmux makes.
NEEDS a hook in ghostel-tmux for a new pane buffer.")

;; Roost asks `derived-mode-p' of `tmux-control-mode', and then for the
;; buffer's session, which a plain Ghostel terminal has none of.
(derived-mode-add-parents 'ghostel-mode '(tmux-control-mode))


;;; Which session a buffer belongs to

(defvar-local tmux-control--place nil
  "The (HOST SOCKET SESSION) of this controller or pane buffer.
NEEDS the socket and host of a session from ghostel-tmux, which knows
neither: it has no socket option, and a host only as the remote part of
`default-directory'.")

(defun tmux-control--controller ()
  "The live controller of the current buffer, a pane's or itself, or nil."
  (let ((controller (or ghostel-tmux--controller-buffer
                        (and ghostel-tmux--controller-process (current-buffer)))))
    (and (buffer-live-p controller) controller)))

(defun tmux-control--buffer-place ()
  "The place of the current buffer.  A pane buffer keeps its controller's."
  (or tmux-control--place
      (when-let* ((controller (tmux-control--controller))
                  (place (buffer-local-value 'tmux-control--place controller)))
        (setq tmux-control--place place))))

(defun tmux-control-buffer-host ()
  "Return the SSH host of the current buffer's connection, nil when local."
  (nth 0 (tmux-control--buffer-place)))

(defun tmux-control-buffer-socket-name ()
  "Return the tmux socket name of the current buffer's connection."
  (nth 1 (tmux-control--buffer-place)))

(defun tmux-control-buffer-session ()
  "Return the tmux session name of the current buffer's connection."
  (nth 2 (tmux-control--buffer-place)))

(defun tmux-control-active-pane ()
  "Return the id of the tmux pane the current buffer sends input to.
A pane buffer of ghostel-tmux is one pane for good."
  (and ghostel-tmux--pane-id
       (tmux-control--buffer-place)
       (format "%%%d" ghostel-tmux--pane-id)))

(defun tmux-control-window-id ()
  "Return the id of the tmux window holding the current buffer's pane."
  (and ghostel-tmux--window-id
       (tmux-control--buffer-place)
       (format "@%d" ghostel-tmux--window-id)))


;;; Connecting

(defvar tmux-control--socket-paths (make-hash-table :test #'equal)
  "The path of each remote socket, by (HOST . SOCKET).")

(defun tmux-control--socket-args (host socket)
  "The arguments that have tmux use SOCKET on HOST.
On a remote host, the path `tmux-control-remote-tmux-socket-setup' puts
it at, asked of the host once.
NEEDS, for a remote host, a way to run a command before tmux there, or
to name a socket by its path."
  (if (not host)
      (list "-L" socket)
    (let ((path (or (gethash (cons host socket) tmux-control--socket-paths)
                    (let ((default-directory (format "/ssh:%s:" host)))
                      (with-temp-buffer
                        (and (eql 0 (process-file
                                     "sh" nil t nil "-c"
                                     (concat tmux-control-remote-tmux-socket-setup
                                             " && printf %s \"$TMUX_TMPDIR/tmux-$(id -u)/$1\"")
                                     "sh" socket))
                             (puthash (cons host socket) (string-trim (buffer-string))
                                      tmux-control--socket-paths)))))))
      (if path (list "-S" path) (list "-L" socket)))))

(define-advice ghostel-tmux--process-file (:around (fn &rest args) tmux-control-socket)
  "Run tmux on the socket of the current buffer's session.
NEEDS a socket option: ghostel-tmux asks tmux whether a session still
exists, and without this would ask the default server."
  (let ((place (tmux-control--buffer-place)))
    (apply fn (if place
                  (append (tmux-control--socket-args (nth 0 place) (nth 1 place)) args)
                args))))

(defun tmux-control--find-controller (place)
  "The live controller attached to PLACE, or nil."
  (seq-find (lambda (buffer)
              (and (equal (buffer-local-value 'tmux-control--place buffer) place)
                   (process-live-p
                    (buffer-local-value 'ghostel-tmux--controller-process buffer))))
            (buffer-list)))

(defun tmux-control--snapshots (place)
  "The pane buffers left of a connection to PLACE that ended."
  (seq-filter (lambda (buffer)
                (and (equal (buffer-local-value 'tmux-control--place buffer) place)
                     (buffer-local-value 'ghostel-tmux-pane-mode buffer)
                     (not (buffer-live-p
                           (buffer-local-value 'ghostel-tmux--controller-buffer buffer)))))
              (buffer-list)))

(defun tmux-control-connect-or-switch (host socket-name session)
  "Show tmux SESSION from HOST and SOCKET-NAME in the selected window.
A live connection to the session is reused.
NEEDS, of ghostel-tmux: an attach that takes a socket (here through the
private `ghostel-tmux--spawn-controller'), one that finds a session
already attached rather than attaching twice, and one that does not
wait: `ghostel-tmux--wait-for-pane' blocks Emacs for up to five seconds."
  (let* ((host (and host (not (string-empty-p host)) host))
         (socket (or socket-name tmux-control-default-socket-name))
         (place (list host socket session))
         (window (selected-window))
         (snapshots (tmux-control--snapshots place))
         (controller (tmux-control--find-controller place)))
    (if controller
        (with-current-buffer controller
          (if-let* ((pane (ghostel-tmux--attach-pane)))
              (ghostel-tmux--display-pane-in-window pane window)
            (setq ghostel-tmux--auto-host-window window)))
      (let ((default-directory (if host (format "/ssh:%s:" host) (expand-file-name "~/"))))
        (ghostel-tmux--check-spawn)
        (let ((controller (ghostel-tmux--spawn-controller
                           session
                           (append (tmux-control--socket-args host socket)
                                   (ghostel-tmux--attach-args session)))))
          (with-current-buffer controller
            (setq tmux-control--place place))
          (ghostel-tmux--wait-for-pane controller 5.0))))
    ;; What a connection that ended left behind, now that the window
    ;; shows the session again.
    (mapc #'kill-buffer snapshots)))

(defun tmux-control-connect (&optional host socket-name session)
  "Show tmux SESSION from HOST and SOCKET-NAME, creating it if it is not there.
Not one of Roost's calls: its tests connect a terminal of your own."
  (let ((socket (or socket-name tmux-control-default-socket-name)))
    (unless (or host
                (eql 0 (call-process ghostel-tmux-program nil nil nil
                                     "-L" socket "has-session" "-t" (concat "=" session))))
      (call-process ghostel-tmux-program nil nil nil "-L" socket "new-session" "-d" "-s" session))
    (tmux-control-connect-or-switch host socket session)))

(defun tmux-control-disconnect ()
  "Disconnect the current buffer's client, keeping its panes as they were.
NEEDS nothing private, but ghostel-tmux kills the pane buffers of a
session it detached unless `ghostel-tmux-keep-detached-panes' says
otherwise, where tmux-control keeps the terminal for a reconnect."
  (interactive)
  (when-let* ((controller (tmux-control--controller)))
    (let ((ghostel-tmux-keep-detached-panes t))
      (with-current-buffer controller
        (ghostel-tmux-detach)))))

(defun tmux-control-reconnect ()
  "Connect the session the current buffer showed again, in the selected window.
NEEDS a reconnect in ghostel-tmux: after a connection ends, its pane
buffers are read-only snapshots, and attaching makes new buffers."
  (interactive)
  (let ((place (or (tmux-control--buffer-place)
                   (user-error "No tmux session recorded in this buffer"))))
    (apply #'tmux-control-connect-or-switch place)))


;;; Commands to tmux

(defun tmux-control-send-command (command)
  "Send tmux COMMAND over the current buffer's connection.
NEEDS a public way to send a command: `ghostel-tmux--queue-command'."
  (when-let* ((controller (tmux-control--controller)))
    (with-current-buffer controller
      (ghostel-tmux--queue-command command))))

(defun tmux-control-query (command callback)
  "Send tmux COMMAND and call CALLBACK with its reply's lines, or nil.
NEEDS the same as `tmux-control-send-command', with the reply."
  (when-let* ((controller (tmux-control--controller)))
    (with-current-buffer controller
      (ghostel-tmux--queue-command
       command
       (lambda (output)
         (funcall callback (and output (split-string output "\n" t))))))))

(defun tmux-control-select-pane (&optional pane)
  "Show and select PANE, a pane id such as \"%3\", of the current session.
NEEDS a public way to show a pane by its id in a window:
`ghostel-tmux--display-pane-in-window' and
`ghostel-tmux--select-pane-buffer'."
  (when-let* ((controller (tmux-control--controller))
              ((stringp pane))
              ((string-match "\\`%\\([0-9]+\\)\\'" pane)))
    (let* ((id (string-to-number (match-string 1 pane)))
           (panes (buffer-local-value 'ghostel-tmux--panes controller))
           (buffer (and panes (gethash id panes)))
           (window (selected-window)))
      (if (not (buffer-live-p buffer))
          ;; Not told of the pane yet: tmux's report of the selection
          ;; shows it.
          (with-current-buffer controller
            (ghostel-tmux--queue-command (format "select-pane -t %s" pane)))
        (unless (get-buffer-window buffer)
          (with-current-buffer controller
            (ghostel-tmux--display-pane-in-window buffer window)))
        (ghostel-tmux--select-pane-buffer buffer)
        (when-let* ((shown (get-buffer-window buffer)))
          (select-window shown))))))


;;; A window's panes side by side

(defun tmux-control-tiled-p ()
  "Return non-nil when the current buffer's tmux window shows as a split.
ghostel-tmux splits a tmux window of several panes by itself, with
`ghostel-tmux-split-windows'.
NEEDS a public way to ask: `ghostel-tmux--tile-windows'."
  (when-let* ((controller (tmux-control--controller))
              (window ghostel-tmux--window-id))
    (and (ghostel-tmux--tile-windows controller window) t)))

(defun tmux-control-tile ()
  "Show every pane of the current tmux window, as tmux lays them out."
  (interactive)
  (when (tmux-control--controller)
    (ghostel-tmux-restore-split)))


;;; A new pane buffer

(define-advice ghostel-tmux--get-or-create-pane
    (:around (fn controller pane-id &rest args) tmux-control-window-buffer)
  "Run `tmux-control-window-buffer-functions' for a pane buffer just made."
  (let* ((panes (buffer-local-value 'ghostel-tmux--panes controller))
         (known (and panes (gethash pane-id panes)))
         (buffer (apply fn controller pane-id args)))
    (unless (buffer-live-p known)
      (with-current-buffer buffer
        (setq tmux-control--place (buffer-local-value 'tmux-control--place controller)))
      (run-hook-with-args 'tmux-control-window-buffer-functions buffer))
    buffer))

(provide 'tmux-control)
;;; tmux-control.el ends here
