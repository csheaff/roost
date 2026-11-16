;;; tmux-control.el --- Trial: what Roost calls of tmux-control, on ghostel-tmux  -*- lexical-binding: t; -*-

;; Version: 99.0
;; Package-Requires: ((emacs "30.1") (ghostel "0.65.0") (ghostel-tmux "0.3.0"))
;; Written against ghostel-tmux's pull request #19 at fdbf32b (2026-11-14):
;; main at 56f2dd4 with functions and hooks for packages that build on it.

;;; Commentary:

;; A trial, not for release.  Roost reaches its terminals through about
;; twenty functions, two hooks and one mode of tmux-control.  This file
;; gives them the same names on top of ghostel-tmux, so that Roost runs
;; unchanged with this directory on the load path in place of
;; tmux-control's:
;;
;;   emacs -L trial/ghostel-tmux -L <ghostel>/lisp -L <ghostel-tmux> ...
;;
;; It calls nothing private of ghostel-tmux: what it needed is public
;; with pull request #19.  A definition that still has to work around
;; something says so, marked NEEDS.

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
  "Functions called with each pane buffer ghostel-tmux makes.")

;; Roost asks `derived-mode-p' of `tmux-control-mode', and then for the
;; buffer's session, which a plain Ghostel terminal has none of.
(derived-mode-add-parents 'ghostel-mode '(tmux-control-mode))

(define-derived-mode tmux-control-connecting-mode special-mode "Connecting"
  "For the buffer a window shows until its tmux session's pane arrives.")
(derived-mode-add-parents 'tmux-control-connecting-mode '(tmux-control-mode))


;;; Which session a buffer belongs to

(defvar-local tmux-control--place nil
  "The (HOST SOCKET SESSION) of this controller, pane or stand-in buffer.
ghostel-tmux has no accessor for a session's socket and host.  This file
attached the session, so it notes what it passed: on the controller,
and on each pane, which keeps it once its session is detached.")

(defvar-local tmux-control--stand-in nil
  "In a controller, the buffer that stands in for its pane until it arrives.
`ghostel-tmux-attach' returns before any pane is there.  Roost needs a
buffer of the session in the window at once, as tmux-control's terminal
was: it sends the session commands from the window's buffer right after
it connects, and it drops an open whose window shows another session by
the time its host replies.")

(defvar-local tmux-control--stands-in-for nil
  "In a buffer standing in for a pane, the controller it waits for.")

(defun tmux-control--controller ()
  "The controller of the current buffer's attached session, or nil.
A pane's, the one a stand-in waits for, or the buffer itself."
  (let ((controller (or (ghostel-tmux-controller) tmux-control--stands-in-for)))
    (and (memq controller (ghostel-tmux-controllers)) controller)))

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
  (and (tmux-control--buffer-place) (ghostel-tmux-pane-id)))

(defun tmux-control-window-id ()
  "Return the id of the tmux window holding the current buffer's pane."
  (and (tmux-control--buffer-place) (ghostel-tmux-window-id)))


;;; Connecting

(defvar tmux-control--socket-paths (make-hash-table :test #'equal)
  "The path of each remote socket, by (HOST . SOCKET).")

(defvar tmux-control--prepared-hosts nil
  "The remote hosts `tmux-control--prepare-host' has set up.")

(defun tmux-control--prepare-host (host)
  "Set up TRAMP and ghostel-tmux for HOST, once, before its first attach.
ghostel-tmux reaches a host's tmux through TRAMP.  With TRAMP's own
processes, on a real host, Roost stalls soon after a task opens: its
pane stays blank and Roost's poll of the host never ends (7 runs of 8
on 2026-11-15).  With direct async processes, which run tmux by an ssh
of its own, it does not, where the host takes a command that long.
And TRAMP's path on the host can leave tmux
out, as where it is a snap: the tmux named is the one a plain ssh
finds, which is how Roost's helper runs it."
  (unless (member host tmux-control--prepared-hosts)
    (push host tmux-control--prepared-hosts)
    (let* ((name (tramp-dissect-file-name (format "/ssh:%s:" host)))
           (profile (intern (format "tmux-control-host-%s" host)))
           (said (with-temp-buffer
                   (and (eql 0 (ignore-errors
                                 (call-process "ssh" nil t nil "-o" "BatchMode=yes"
                                               "-o" "ConnectTimeout=8" "--" host
                                               "command -v tmux; getconf PIPE_BUF /")))
                        (split-string (buffer-string) "\n" t "[ \t]+"))))
           (tmux (seq-find #'file-name-absolute-p said))
           (longest (seq-some (lambda (line)
                                (and (string-match-p "\\`[0-9]+\\'" line)
                                     (string-to-number line)))
                              said)))
      (connection-local-set-profile-variables
       profile
       ;; A direct async process is one command line, no longer than the
       ;; host's PIPE_BUF, TRAMP holds: 4096 on Linux, where attaching
       ;; fits, and 512 on macOS, where it does not.
       `(,@(and longest (>= longest 4096)
                '((tramp-direct-async-process . t)))
         ,@(and tmux `((ghostel-tmux-program . ,tmux)))))
      (connection-local-set-profiles
       `(:application tramp :machine ,(tramp-file-name-host name)
                      ,@(and (tramp-file-name-user name)
                             (list :user (tramp-file-name-user name))))
       profile))))

(defun tmux-control--socket (host socket)
  "SOCKET on HOST as `ghostel-tmux-attach' takes it: a name, or a path.
On a remote host, the path `tmux-control-remote-tmux-socket-setup' puts
it at, asked of the host once: Roost's helper runs that setup before
tmux, and ghostel-tmux has no command to run first."
  (if (not host)
      socket
    (tmux-control--prepare-host host)
    (or (gethash (cons host socket) tmux-control--socket-paths)
        (let ((default-directory (format "/ssh:%s:" host)))
          (with-temp-buffer
            (and (eql 0 (process-file
                         "sh" nil t nil "-c"
                         (concat tmux-control-remote-tmux-socket-setup
                                 " && printf %s \"$TMUX_TMPDIR/tmux-$(id -u)/$1\"")
                         "sh" socket))
                 (puthash (cons host socket) (string-trim (buffer-string))
                          tmux-control--socket-paths))))
        socket)))

(defun tmux-control--find-controller (place)
  "The controller attached to PLACE, or nil."
  (seq-find (lambda (buffer)
              (equal (buffer-local-value 'tmux-control--place buffer) place))
            (ghostel-tmux-controllers)))

(defun tmux-control--snapshots (place)
  "The pane buffers left of a connection to PLACE that ended."
  (seq-filter (lambda (buffer)
                (and (equal (buffer-local-value 'tmux-control--place buffer) place)
                     (buffer-local-value 'ghostel-tmux-pane-mode buffer)
                     (not (ghostel-tmux-controller buffer))))
              (buffer-list)))

(defun tmux-control--attach (place no-display)
  "Attach the session at PLACE and return its controller.
With NO-DISPLAY, no window waits for its pane: its stand-in does.
ghostel-tmux says in the echo area that it attaches, and later that it
has, by the name of a session Roost made and around what Roost says
there of the task: `inhibit-message' has it say neither."
  (let* ((host (nth 0 place))
         (default-directory (if host (format "/ssh:%s:" host)
                              (expand-file-name "~/")))
         (path (tmux-control--socket host (nth 1 place)))
         (controller (let ((inhibit-message t))
                       (ghostel-tmux-attach (nth 2 place) path no-display))))
    (with-current-buffer controller
      (setq tmux-control--place place))
    controller))

(defun tmux-control--pane (controller)
  "The pane buffer a window is to show for CONTROLLER's session, or nil.
tmux's active pane, or the session's first should that one have no
buffer."
  (or (ghostel-tmux-active-pane controller)
      (car (ghostel-tmux-panes controller))))

(defun tmux-control--show-pane (pane window)
  "Show the buffer PANE in WINDOW.
ghostel-tmux fits a pane to a window that comes to show it, and has the
pane take the place of a split of another tmux window.  A split of the
pane's own tmux window shows its panes already."
  (when (and (window-live-p window) (buffer-live-p pane))
    (unless (seq-some
             (lambda (other)
               (let ((shown (window-buffer other)))
                 (and (eq (ghostel-tmux-controller shown)
                          (ghostel-tmux-controller pane))
                      (equal (ghostel-tmux-window-id shown)
                             (ghostel-tmux-window-id pane)))))
             (ghostel-tmux-window-split window))
      (with-selected-window window
        (switch-to-buffer pane t)))))

(defun tmux-control--stand-in-for (place &optional shown)
  "Return a buffer to stand in for the pane of the session at PLACE.
SHOWN if it is one for PLACE already, else a new one."
  (if (and (buffer-live-p shown)
           (eq (buffer-local-value 'major-mode shown) 'tmux-control-connecting-mode)
           (equal (buffer-local-value 'tmux-control--place shown) place))
      shown
    (let ((buffer (generate-new-buffer (format "*tmux-control: %s*" (nth 2 place)))))
      (with-current-buffer buffer
        (tmux-control-connecting-mode)
        (setq tmux-control--place place)
        (let ((inhibit-read-only t))
          (insert (format "Connecting to %s…\n" (nth 2 place)))))
      (run-hook-with-args 'tmux-control-window-buffer-functions buffer)
      buffer)))

(defun tmux-control--show-stand-in (stand-in controller window)
  "Show STAND-IN for CONTROLLER's pane in WINDOW.
A split of another session that WINDOW is part of gives way to it
first, as it does when ghostel-tmux shows a pane of another session
there: the stand-in would sit beside that session's other panes."
  (when controller
    (with-current-buffer controller
      (setq tmux-control--stand-in stand-in))
    (with-current-buffer stand-in
      (setq tmux-control--stands-in-for controller)))
  (unless (eq (window-buffer window) stand-in)
    (dolist (other (ghostel-tmux-window-split window))
      (unless (eq other window)
        (ignore-errors (delete-window other))))
    (when (window-live-p window)
      (with-selected-window window
        (switch-to-buffer stand-in t)))))

(defun tmux-control--sweep-stand-ins ()
  "Kill the stand-ins no window shows whose pane has come or never will."
  (dolist (buffer (buffer-list))
    (when (and (eq (buffer-local-value 'major-mode buffer) 'tmux-control-connecting-mode)
               (not (get-buffer-window buffer t)))
      (let ((controller (buffer-local-value 'tmux-control--stands-in-for buffer)))
        (unless (and (memq controller (ghostel-tmux-controllers))
                     (not (tmux-control--pane controller)))
          (kill-buffer buffer))))))

(defun tmux-control-connect-or-switch (host socket-name session)
  "Show tmux SESSION from HOST and SOCKET-NAME in the selected window.
A live connection to the session is reused.  The panes a connection
that ended left behind come alive again, as ghostel-tmux does it.
Returns before the pane is there: until tmux reports it the window shows
a buffer that stands in for it."
  (let* ((host (and host (not (string-empty-p host)) host))
         (socket (or socket-name tmux-control-default-socket-name))
         (place (list host socket session))
         (window (selected-window))
         (shown (window-buffer window))
         (controller (tmux-control--find-controller place))
         (pane (and controller (tmux-control--pane controller))))
    (tmux-control--sweep-stand-ins)
    (cond
     (pane
      (tmux-control--show-pane pane window))
     (controller
      ;; Its first pane is yet to come: this window waits for it too.
      (tmux-control--show-stand-in
       (or (let ((stand-in (buffer-local-value 'tmux-control--stand-in controller)))
             (and (buffer-live-p stand-in) stand-in))
           (tmux-control--stand-in-for place shown))
       controller window))
     ((memq shown (tmux-control--snapshots place))
      ;; A pane the session's last connection left: ghostel-tmux makes it
      ;; live again where it is, in the window it keeps for the session.
      (tmux-control--attach place nil))
     (t
      (let ((stand-in (tmux-control--stand-in-for place shown)))
        (tmux-control--show-stand-in stand-in nil window)
        (condition-case err
            (tmux-control--show-stand-in
             stand-in (tmux-control--attach place t) window)
          ((error quit)
           (when (and (window-live-p window) (eq (window-buffer window) stand-in)
                      (buffer-live-p shown) (not (eq shown stand-in)))
             (set-window-buffer window shown))
           (kill-buffer stand-in)
           (signal (car err) (cdr err)))))))))

(defun tmux-control--attached ()
  "Put the session's pane wherever its stand-in shows.
On `ghostel-tmux-attach-hook', in the controller: tmux has listed the
session's windows, and no minibuffer is open, whose closing would put
the stand-in back in its window.  By now every pane tmux still has is
live again: the pane buffers an earlier connection left that are not,
tmux no longer has."
  (when-let* ((place tmux-control--place))
    (when-let* ((stand-in tmux-control--stand-in)
                ((buffer-live-p stand-in))
                (pane (tmux-control--pane (current-buffer))))
      (dolist (window (get-buffer-window-list stand-in nil t))
        (tmux-control--show-pane pane window))
      (setq tmux-control--stand-in nil)
      (kill-buffer stand-in))
    (mapc #'kill-buffer (tmux-control--snapshots place))))

(add-hook 'ghostel-tmux-attach-hook #'tmux-control--attached)

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
  "Disconnect the current buffer's client, keeping its panes as they were."
  (interactive)
  (when-let* ((controller (tmux-control--controller)))
    (ghostel-tmux-detach t controller)))

(defun tmux-control-reconnect ()
  "Connect the session the current buffer showed again, in the selected window.
Attaching makes its sealed pane buffers live again."
  (interactive)
  (let ((place (or (tmux-control--buffer-place)
                   (user-error "No tmux session recorded in this buffer"))))
    (apply #'tmux-control-connect-or-switch place)))


;;; Commands to tmux

(defun tmux-control--command (controller command &optional callback)
  "Send tmux COMMAND through CONTROLLER.
CALLBACK is called with what it printed and tmux's error message, or nil.
A command tmux refuses is not reported: Roost did not ask the user's.
`ghostel-tmux-command' holds one given before tmux has started, as
Roost's is right after it connects.  Nothing is sent to a tmux that is
leaving."
  (condition-case nil
      (ghostel-tmux-command command (or callback #'ignore) controller)
    (user-error nil)))

(defun tmux-control-send-command (command)
  "Send tmux COMMAND over the current buffer's connection."
  (when-let* ((controller (tmux-control--controller)))
    (tmux-control--command controller command)))

(defun tmux-control-query (command callback)
  "Send tmux COMMAND and call CALLBACK with its reply's lines, or nil."
  (when-let* ((controller (tmux-control--controller)))
    (tmux-control--command
     controller command
     (lambda (output failure)
       (funcall callback (and (not failure) (split-string output "\n" t)))))))

(defun tmux-control-select-pane (&optional pane)
  "Show and select PANE, a pane id such as \"%3\", of the current session."
  (when-let* ((controller (tmux-control--controller))
              ((stringp pane))
              ((string-match-p "\\`%[0-9]+\\'" pane)))
    (if-let* ((buffer (ghostel-tmux-pane-buffer pane controller)))
        (ghostel-tmux-select-pane buffer)
      ;; Not told of the pane yet: tmux's report of the selection shows it.
      (tmux-control--command controller (format "select-pane -t %s" pane)))))


;;; A window's panes side by side

(defun tmux-control-tiled-p ()
  "Return non-nil when the current buffer's tmux window shows as a split.
ghostel-tmux splits a tmux window of several panes by itself, with
`ghostel-tmux-split-windows'."
  (and (tmux-control--controller)
       (seq-some #'ghostel-tmux-window-split
                 (get-buffer-window-list (current-buffer) nil t))
       t))

(defun tmux-control-tile ()
  "Show every pane of the current tmux window, as tmux lays them out."
  (interactive)
  (when (tmux-control--controller)
    (ghostel-tmux-restore-split)))


;;; A new pane buffer

(defun tmux-control--pane-made ()
  "Note the place of a pane buffer and run `tmux-control-window-buffer-functions'.
On `ghostel-tmux-pane-mode-hook', which runs in a pane buffer that was
made, or made live again by an attach."
  (when-let* ((ghostel-tmux-pane-mode)
              (controller (ghostel-tmux-controller))
              (place (buffer-local-value 'tmux-control--place controller)))
    (setq tmux-control--place place)
    (run-hook-with-args 'tmux-control-window-buffer-functions (current-buffer))))

(add-hook 'ghostel-tmux-pane-mode-hook #'tmux-control--pane-made)

(provide 'tmux-control)
;;; tmux-control.el ends here
