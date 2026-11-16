;;; roost-ghostel-tmux.el --- Roost's terminals through ghostel-tmux  -*- lexical-binding: t; -*-

;; Author: Clay Sheaff
;; URL: https://github.com/csheaff/roost
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; What Roost asks of the package that shows a task's tmux session, on
;; ghostel-tmux, which draws it through Ghostel.  Roost loads this file
;; when `roost-terminal-backend' is `ghostel-tmux'; with the default,
;; tmux-control, it is never loaded.
;;
;; It needs Ghostel 0.65.0 and ghostel-tmux 0.3.0 or newer, which Roost
;; does not install.  Each function here has the name and arguments of
;; the one of tmux-control it stands for, after the prefix.  A definition
;; that still has to work around something in ghostel-tmux says so,
;; marked NEEDS.

;;; Code:

(require 'seq)
(unless (require 'ghostel-tmux nil t)
  (error "Roost's ghostel-tmux terminals need the package ghostel-tmux"))

(defvar ghostel-tmux-program)
(defvar ghostel-tmux-pane-mode)
(declare-function ghostel-tmux-controller "ghostel-tmux" (&optional buffer))
(declare-function ghostel-tmux-controllers "ghostel-tmux" ())
(declare-function ghostel-tmux-pane-id "ghostel-tmux" (&optional buffer))
(declare-function ghostel-tmux-window-id "ghostel-tmux" (&optional buffer))
(declare-function ghostel-tmux-attach "ghostel-tmux" (session &optional socket no-display))
(declare-function ghostel-tmux-active-pane "ghostel-tmux" (&optional buffer))
(declare-function ghostel-tmux-panes "ghostel-tmux" (&optional buffer))
(declare-function ghostel-tmux-window-split "ghostel-tmux" (&optional window))
(declare-function ghostel-tmux-detach "ghostel-tmux" (&optional keep buffer))
(declare-function ghostel-tmux-command "ghostel-tmux" (command &optional callback buffer))
(declare-function ghostel-tmux-pane-buffer "ghostel-tmux" (pane-id &optional buffer))
(declare-function ghostel-tmux-select-pane "ghostel-tmux" (pane))
(declare-function ghostel-tmux-restore-split "ghostel-tmux" ())
(declare-function tramp-dissect-file-name "tramp" (name &optional nodefault))
(declare-function tramp-file-name-host "tramp" (cl-x))
(declare-function tramp-file-name-user "tramp" (cl-x))

(defgroup roost-ghostel-tmux nil
  "Roost's terminals through ghostel-tmux."
  :group 'roost)

(defcustom roost-ghostel-tmux-default-socket-name "main"
  "The tmux socket for tasks when `roost-socket-name' is nil."
  :type 'string)

(defvar roost-ghostel-tmux-remote-tmux-socket-setup
  "fs=$(stat -f -c %T \"$HOME\" 2>/dev/null); case \"$fs\" in nfs|nfs4|lustre|gpfs|cifs|smb*|afs) d=\"/tmp/tmux-$(id -u)-sock\";; *) d=\"$HOME/.tmux-sock\";; esac; mkdir -p \"$d\" && chmod 700 \"$d\" && export TMUX_TMPDIR=\"$d\""
  "Shell snippet run before tmux on a remote host, as tmux-control has it.
Roost's helper runs it too, so both find the same tmux server.")

(defvar roost-ghostel-tmux-window-buffer-functions nil
  "Functions called with each pane buffer ghostel-tmux makes.")

(define-derived-mode roost-ghostel-tmux-connecting-mode special-mode "Connecting"
  "For the buffer a window shows until its tmux session's pane arrives.")

(defun roost-ghostel-tmux-buffer-p ()
  "Whether the current buffer could be a terminal of a tmux session.
A Ghostel terminal, or a buffer that stands in for one on its way."
  (derived-mode-p 'ghostel-mode 'roost-ghostel-tmux-connecting-mode))


;;; Which session a buffer belongs to

(defvar-local roost-ghostel-tmux--place nil
  "The (HOST SOCKET SESSION) of this controller, pane or stand-in buffer.
ghostel-tmux has no accessor for a session's socket and host.  This file
attached the session, so it notes what it passed: on the controller,
and on each pane, which keeps it once its session is detached.")

(defvar roost-ghostel-tmux--lost (make-hash-table :test #'equal)
  "How often each place whose connection dropped has been tried again.")

(defvar-local roost-ghostel-tmux--was-attached nil
  "Non-nil in a controller whose session's panes have arrived.")

(defvar-local roost-ghostel-tmux--stand-in nil
  "In a controller, the buffer that stands in for its pane until it arrives.
`ghostel-tmux-attach' returns before any pane is there.  Roost needs a
buffer of the session in the window at once, as tmux-control's terminal
was: it sends the session commands from the window's buffer right after
it connects, and it drops an open whose window shows another session by
the time its host replies.")

(defvar-local roost-ghostel-tmux--stands-in-for nil
  "In a buffer standing in for a pane, the controller it waits for.")

(defun roost-ghostel-tmux--controller ()
  "The controller of the current buffer's attached session, or nil.
A pane's, the one a stand-in waits for, or the buffer itself."
  (let ((controller (or (ghostel-tmux-controller) roost-ghostel-tmux--stands-in-for)))
    (and (memq controller (ghostel-tmux-controllers)) controller)))

(defun roost-ghostel-tmux--buffer-place ()
  "The place of the current buffer.  A pane buffer keeps its controller's."
  (or roost-ghostel-tmux--place
      (when-let* ((controller (roost-ghostel-tmux--controller))
                  (place (buffer-local-value 'roost-ghostel-tmux--place controller)))
        (setq roost-ghostel-tmux--place place))))

(defun roost-ghostel-tmux-buffer-host ()
  "Return the SSH host of the current buffer's connection, nil when local."
  (nth 0 (roost-ghostel-tmux--buffer-place)))

(defun roost-ghostel-tmux-buffer-socket-name ()
  "Return the tmux socket name of the current buffer's connection."
  (nth 1 (roost-ghostel-tmux--buffer-place)))

(defun roost-ghostel-tmux-buffer-session ()
  "Return the tmux session name of the current buffer's connection."
  (nth 2 (roost-ghostel-tmux--buffer-place)))

(defun roost-ghostel-tmux-active-pane ()
  "Return the id of the tmux pane the current buffer sends input to.
A pane buffer of ghostel-tmux is one pane for good."
  (and (roost-ghostel-tmux--buffer-place) (ghostel-tmux-pane-id)))

(defun roost-ghostel-tmux-window-id ()
  "Return the id of the tmux window holding the current buffer's pane."
  (and (roost-ghostel-tmux--buffer-place) (ghostel-tmux-window-id)))


;;; Connecting

(defvar roost-ghostel-tmux--socket-paths (make-hash-table :test #'equal)
  "The path of each remote socket, by (HOST . SOCKET).")

(defvar roost-ghostel-tmux--prepared-hosts nil
  "The remote hosts `roost-ghostel-tmux--prepare-host' has set up.")

(defun roost-ghostel-tmux--prepare-host (host)
  "Set up TRAMP and ghostel-tmux for HOST, once, before its first attach.
ghostel-tmux reaches a host's tmux through TRAMP.  With TRAMP's own
processes, on a real host, Roost stalls soon after a task opens: its
pane stays blank and Roost's poll of the host never ends (7 runs of 8
on 2026-11-15).  With direct async processes, which run tmux by an ssh
of its own, it does not, where the host takes a command that long.
And TRAMP's path on the host can leave tmux
out, as where it is a snap: the tmux named is the one a plain ssh
finds, which is how Roost's helper runs it."
  (unless (member host roost-ghostel-tmux--prepared-hosts)
    (require 'tramp)
    (push host roost-ghostel-tmux--prepared-hosts)
    (let* ((name (tramp-dissect-file-name (format "/ssh:%s:" host)))
           (profile (intern (format "roost-ghostel-tmux-host-%s" host)))
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

(defun roost-ghostel-tmux--socket (host socket)
  "SOCKET on HOST as `ghostel-tmux-attach' takes it: a name, or a path.
On a remote host, the path `roost-ghostel-tmux-remote-tmux-socket-setup' puts
it at, asked of the host once: Roost's helper runs that setup before
tmux, and ghostel-tmux has no command to run first."
  (if (not host)
      socket
    (roost-ghostel-tmux--prepare-host host)
    (or (gethash (cons host socket) roost-ghostel-tmux--socket-paths)
        (let ((default-directory (format "/ssh:%s:" host)))
          (with-temp-buffer
            (and (eql 0 (process-file
                         "sh" nil t nil "-c"
                         (concat roost-ghostel-tmux-remote-tmux-socket-setup
                                 " && printf %s \"$TMUX_TMPDIR/tmux-$(id -u)/$1\"")
                         "sh" socket))
                 (puthash (cons host socket) (string-trim (buffer-string))
                          roost-ghostel-tmux--socket-paths))))
        socket)))

(defun roost-ghostel-tmux--find-controller (place)
  "The controller attached to PLACE, or nil."
  (seq-find (lambda (buffer)
              (equal (buffer-local-value 'roost-ghostel-tmux--place buffer) place))
            (ghostel-tmux-controllers)))

(defun roost-ghostel-tmux--snapshots (place)
  "The pane buffers left of a connection to PLACE that ended."
  (seq-filter (lambda (buffer)
                (and (equal (buffer-local-value 'roost-ghostel-tmux--place buffer) place)
                     (buffer-local-value 'ghostel-tmux-pane-mode buffer)
                     (not (ghostel-tmux-controller buffer))))
              (buffer-list)))

(defun roost-ghostel-tmux--attach (place no-display)
  "Attach the session at PLACE and return its controller.
With NO-DISPLAY, no window waits for its pane: its stand-in does.
ghostel-tmux says in the echo area that it attaches, and later that it
has, by the name of a session Roost made and around what Roost says
there of the task: `inhibit-message' has it say neither."
  (let* ((host (nth 0 place))
         (default-directory (if host (format "/ssh:%s:" host)
                              (expand-file-name "~/")))
         (path (roost-ghostel-tmux--socket host (nth 1 place)))
         (controller (let ((inhibit-message t))
                       (ghostel-tmux-attach (nth 2 place) path no-display))))
    (with-current-buffer controller
      (setq roost-ghostel-tmux--place place))
    controller))

(defun roost-ghostel-tmux--pane (controller)
  "The pane buffer a window is to show for CONTROLLER's session, or nil.
tmux's active pane, or the session's first should that one have no
buffer."
  (or (ghostel-tmux-active-pane controller)
      (car (ghostel-tmux-panes controller))))

(defun roost-ghostel-tmux--show-pane (pane window)
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

(defun roost-ghostel-tmux--stand-in-for (place &optional shown)
  "Return a buffer to stand in for the pane of the session at PLACE.
SHOWN if it is one for PLACE already, else a new one."
  (if (and (buffer-live-p shown)
           (eq (buffer-local-value 'major-mode shown) 'roost-ghostel-tmux-connecting-mode)
           (equal (buffer-local-value 'roost-ghostel-tmux--place shown) place))
      shown
    (let ((buffer (generate-new-buffer (format "*roost-terminal: %s*" (nth 2 place)))))
      (with-current-buffer buffer
        (roost-ghostel-tmux-connecting-mode)
        (setq roost-ghostel-tmux--place place)
        (let ((inhibit-read-only t))
          (insert (format "Connecting to %s…\n" (nth 2 place)))))
      (run-hook-with-args 'roost-ghostel-tmux-window-buffer-functions buffer)
      buffer)))

(defun roost-ghostel-tmux--show-stand-in (stand-in controller window)
  "Show STAND-IN for CONTROLLER's pane in WINDOW.
A split of another session that WINDOW is part of gives way to it
first, as it does when ghostel-tmux shows a pane of another session
there: the stand-in would sit beside that session's other panes."
  (when controller
    (with-current-buffer controller
      (setq roost-ghostel-tmux--stand-in stand-in))
    (with-current-buffer stand-in
      (setq roost-ghostel-tmux--stands-in-for controller)))
  (unless (eq (window-buffer window) stand-in)
    (dolist (other (ghostel-tmux-window-split window))
      (unless (eq other window)
        (ignore-errors (delete-window other))))
    (when (window-live-p window)
      (with-selected-window window
        (switch-to-buffer stand-in t)))))

(defun roost-ghostel-tmux--sweep-stand-ins ()
  "Kill the stand-ins no window shows whose pane has come or never will."
  (dolist (buffer (buffer-list))
    (when (and (eq (buffer-local-value 'major-mode buffer) 'roost-ghostel-tmux-connecting-mode)
               (not (get-buffer-window buffer t)))
      (let ((controller (buffer-local-value 'roost-ghostel-tmux--stands-in-for buffer)))
        (unless (and (memq controller (ghostel-tmux-controllers))
                     (not (roost-ghostel-tmux--pane controller)))
          (kill-buffer buffer))))))

(defun roost-ghostel-tmux-connect-or-switch (host socket-name session)
  "Show tmux SESSION from HOST and SOCKET-NAME in the selected window.
A live connection to the session is reused.  The panes a connection
that ended left behind come alive again, as ghostel-tmux does it.
Returns before the pane is there: until tmux reports it the window shows
a buffer that stands in for it."
  (let* ((host (and host (not (string-empty-p host)) host))
         (socket (or socket-name roost-ghostel-tmux-default-socket-name))
         (place (list host socket session))
         (window (selected-window))
         (shown (window-buffer window))
         (controller (roost-ghostel-tmux--find-controller place))
         (pane (and controller (roost-ghostel-tmux--pane controller))))
    (roost-ghostel-tmux--sweep-stand-ins)
    (cond
     (pane
      (roost-ghostel-tmux--show-pane pane window))
     (controller
      ;; Its first pane is yet to come: this window waits for it too.
      (roost-ghostel-tmux--show-stand-in
       (or (let ((stand-in (buffer-local-value 'roost-ghostel-tmux--stand-in controller)))
             (and (buffer-live-p stand-in) stand-in))
           (roost-ghostel-tmux--stand-in-for place shown))
       controller window))
     ((memq shown (roost-ghostel-tmux--snapshots place))
      ;; A pane the session's last connection left: ghostel-tmux makes it
      ;; live again where it is, in the window it keeps for the session.
      (roost-ghostel-tmux--attach place nil))
     (t
      (let ((stand-in (roost-ghostel-tmux--stand-in-for place shown)))
        (roost-ghostel-tmux--show-stand-in stand-in nil window)
        (condition-case err
            (roost-ghostel-tmux--show-stand-in
             stand-in (roost-ghostel-tmux--attach place t) window)
          ((error quit)
           (when (and (window-live-p window) (eq (window-buffer window) stand-in)
                      (buffer-live-p shown) (not (eq shown stand-in)))
             (set-window-buffer window shown))
           (kill-buffer stand-in)
           (signal (car err) (cdr err)))))))))

(defun roost-ghostel-tmux--attached ()
  "Put the session's pane wherever its stand-in shows.
On `ghostel-tmux-attach-hook', in the controller: tmux has listed the
session's windows, and no minibuffer is open, whose closing would put
the stand-in back in its window.  By now every pane tmux still has is
live again: the pane buffers an earlier connection left that are not,
tmux no longer has."
  (when-let* ((place roost-ghostel-tmux--place))
    (setq roost-ghostel-tmux--was-attached t)
    (remhash place roost-ghostel-tmux--lost)
    (when-let* ((stand-in roost-ghostel-tmux--stand-in)
                ((buffer-live-p stand-in))
                (pane (roost-ghostel-tmux--pane (current-buffer))))
      (dolist (window (get-buffer-window-list stand-in nil t))
        (roost-ghostel-tmux--show-pane pane window))
      (setq roost-ghostel-tmux--stand-in nil)
      (kill-buffer stand-in))
    (mapc #'kill-buffer (roost-ghostel-tmux--snapshots place))))

(add-hook 'ghostel-tmux-attach-hook #'roost-ghostel-tmux--attached)


;;; A connection that drops

;; When the ssh under a session on a host ends, ghostel-tmux keeps the
;; session's panes as they were and says so once in the echo area.  The
;; session is still there, on the host: the layer attaches it again, and
;; the panes it kept come alive where they are.

(defun roost-ghostel-tmux--detached ()
  "Attach again a session on a host whose connection dropped.
On `ghostel-tmux-detach-hook', in the controller.  A session that was
detached, or that tmux said has ended, is left: Roost's helper ends a
task's session.
NEEDS: `ghostel-tmux--detaching' and `ghostel-tmux--closing', to tell a
connection that dropped from a client that was detached or a session
that ended.  The hook could say which."
  (when-let* ((place roost-ghostel-tmux--place)
              ((nth 0 place))
              ((not (bound-and-true-p ghostel-tmux--detaching)))
              ((not (bound-and-true-p ghostel-tmux--closing)))
              ((or roost-ghostel-tmux--was-attached (gethash place roost-ghostel-tmux--lost))))
    (roost-ghostel-tmux--attach-again place)))

(defun roost-ghostel-tmux--attach-again (place)
  "Try the session at PLACE again after a second, then two, up to thirty.
Eight times, about two and a half minutes: after that, opening the task
attaches it."
  (let ((tries (gethash place roost-ghostel-tmux--lost 0)))
    (if (>= tries 8)
        (remhash place roost-ghostel-tmux--lost)
      (puthash place (1+ tries) roost-ghostel-tmux--lost)
      (run-at-time (min 30 (expt 2 tries)) nil #'roost-ghostel-tmux--try-again place))))

(defun roost-ghostel-tmux--try-again (place)
  "Attach the session at PLACE if its host answers, else try later.
The host is asked by an ssh of its own first: an attach goes through
TRAMP, which would hold Emacs for as long as a host that is away takes
to time out.  Nothing is tried once the session is attached again, as
when you opened its task, or once none of its panes is left to bring
back, as when Roost has put them away."
  (cond
   ((not (gethash place roost-ghostel-tmux--lost)))
   ((or (roost-ghostel-tmux--find-controller place)
        (not (roost-ghostel-tmux--snapshots place)))
    (remhash place roost-ghostel-tmux--lost))
   (t
    (make-process
     :name "roost-ghostel-tmux-host-there"
     :command (list "ssh" "-o" "BatchMode=yes" "-o" "ConnectTimeout=5" "--" (nth 0 place) "true")
     :connection-type 'pipe :noquery t
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (if (and (eql 0 (process-exit-status process))
                  (not (roost-ghostel-tmux--find-controller place))
                  (roost-ghostel-tmux--snapshots place))
             (condition-case nil
                 (roost-ghostel-tmux--attach place t)
               (error (roost-ghostel-tmux--attach-again place)))
           (when (gethash place roost-ghostel-tmux--lost)
             (roost-ghostel-tmux--attach-again place)))))))))

(add-hook 'ghostel-tmux-detach-hook #'roost-ghostel-tmux--detached)

(defun roost-ghostel-tmux-connect (&optional host socket-name session)
  "Show tmux SESSION from HOST and SOCKET-NAME, creating it if it is not there.
Not one of Roost's calls: its tests connect a terminal of your own."
  (let ((socket (or socket-name roost-ghostel-tmux-default-socket-name)))
    (unless (or host
                (eql 0 (call-process ghostel-tmux-program nil nil nil
                                     "-L" socket "has-session" "-t" (concat "=" session))))
      (call-process ghostel-tmux-program nil nil nil "-L" socket "new-session" "-d" "-s" session))
    (roost-ghostel-tmux-connect-or-switch host socket session)))

(defun roost-ghostel-tmux-disconnect ()
  "Disconnect the current buffer's client, keeping its panes as they were."
  (interactive)
  (when-let* ((controller (roost-ghostel-tmux--controller)))
    (ghostel-tmux-detach t controller)))

(defun roost-ghostel-tmux-reconnect ()
  "Connect the session the current buffer showed again, in the selected window.
Attaching makes its sealed pane buffers live again."
  (interactive)
  (let ((place (or (roost-ghostel-tmux--buffer-place)
                   (user-error "No tmux session recorded in this buffer"))))
    (apply #'roost-ghostel-tmux-connect-or-switch place)))


;;; Commands to tmux

(defun roost-ghostel-tmux--command (controller command &optional callback)
  "Send tmux COMMAND through CONTROLLER.
CALLBACK is called with what it printed and tmux's error message, or nil.
A command tmux refuses is not reported: Roost did not ask the user's.
`ghostel-tmux-command' holds one given before tmux has started, as
Roost's is right after it connects.  Nothing is sent to a tmux that is
leaving."
  (condition-case nil
      (ghostel-tmux-command command (or callback #'ignore) controller)
    (user-error nil)))

(defun roost-ghostel-tmux-send-command (command)
  "Send tmux COMMAND over the current buffer's connection."
  (when-let* ((controller (roost-ghostel-tmux--controller)))
    (roost-ghostel-tmux--command controller command)))

(defun roost-ghostel-tmux-query (command callback)
  "Send tmux COMMAND and call CALLBACK with its reply's lines, or nil."
  (when-let* ((controller (roost-ghostel-tmux--controller)))
    (roost-ghostel-tmux--command
     controller command
     (lambda (output failure)
       (funcall callback (and (not failure) (split-string output "\n" t)))))))

(defun roost-ghostel-tmux-select-pane (&optional pane)
  "Show and select PANE, a pane id such as \"%3\", of the current session."
  (when-let* ((controller (roost-ghostel-tmux--controller))
              ((stringp pane))
              ((string-match-p "\\`%[0-9]+\\'" pane)))
    (if-let* ((buffer (ghostel-tmux-pane-buffer pane controller)))
        (ghostel-tmux-select-pane buffer)
      ;; Not told of the pane yet: tmux's report of the selection shows it.
      (roost-ghostel-tmux--command controller (format "select-pane -t %s" pane)))))


;;; A window's panes side by side

(defun roost-ghostel-tmux-tiled-p ()
  "Return non-nil when the current buffer's tmux window shows as a split.
ghostel-tmux splits a tmux window of several panes by itself, with
`ghostel-tmux-split-windows'."
  (and (roost-ghostel-tmux--controller)
       (seq-some #'ghostel-tmux-window-split
                 (get-buffer-window-list (current-buffer) nil t))
       t))

(defun roost-ghostel-tmux-tile ()
  "Show every pane of the current tmux window, as tmux lays them out."
  (interactive)
  (when (roost-ghostel-tmux--controller)
    (ghostel-tmux-restore-split)))


;;; A new pane buffer

(defun roost-ghostel-tmux--pane-made ()
  "Note the place of a pane buffer and tell Roost of it.
With `roost-ghostel-tmux-window-buffer-functions'.  On
`ghostel-tmux-pane-mode-hook', which runs in a pane buffer that was made,
or made live again by an attach."
  (when-let* ((ghostel-tmux-pane-mode)
              (controller (ghostel-tmux-controller))
              (place (buffer-local-value 'roost-ghostel-tmux--place controller)))
    (setq roost-ghostel-tmux--place place)
    (run-hook-with-args 'roost-ghostel-tmux-window-buffer-functions (current-buffer))))

(add-hook 'ghostel-tmux-pane-mode-hook #'roost-ghostel-tmux--pane-made)

(provide 'roost-ghostel-tmux)
;;; roost-ghostel-tmux.el ends here
