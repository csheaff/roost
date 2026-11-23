;;; roost-ghostel-tmux.el --- Roost's terminals through ghostel-tmux  -*- lexical-binding: t; -*-

;; Author: Clay Sheaff
;; URL: https://github.com/csheaff/roost
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; What Roost asks of the package that shows a task's tmux session, on
;; ghostel-tmux, which draws it through Ghostel.  Roost loads this file
;; when `roost-terminal-backend' is `ghostel-tmux', its default; with
;; tmux-control it is never loaded.
;;
;; It needs Ghostel 0.65.0 and ghostel-tmux 0.4.0 or newer.  Each
;; function here has the name and arguments of
;; the one of tmux-control it stands for, after the prefix.  A definition
;; that still has to work around something in ghostel-tmux says so,
;; marked NEEDS.

;;; Code:

(require 'seq)
(require 'files-x)
(require 'roost)
(unless (require 'ghostel-tmux nil t)
  (error "Roost's ghostel-tmux terminals need the package ghostel-tmux"))

(defvar ghostel-tmux-program)
(defvar tramp-direct-async-process)
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
(declare-function tramp-file-name-method "tramp" (cl-x))
(declare-function ghostel-tmux-session-name "ghostel-tmux" (&optional buffer))
(declare-function perspectives-hash "perspective" (&optional frame))
(declare-function persp-curr "perspective" (&optional frame))
(declare-function persp-buffers "perspective" (perspective))
(declare-function persp-add-buffer "perspective" (buffer-or-name))

(defgroup roost-ghostel-tmux nil
  "Roost's terminals through ghostel-tmux."
  :group 'roost)

(defvar roost-ghostel-tmux-window-buffer-functions nil
  "Functions called with each pane buffer ghostel-tmux makes.")

(defvar roost-ghostel-tmux--perspective-going nil
  "Non-nil while perspective.el kills a perspective and the buffers only it has.")

(define-derived-mode roost-ghostel-tmux-connecting-mode special-mode "Connecting"
  "For the buffer a window shows until its tmux session's pane arrives."
  ;; As a panel, or else where `q' is not Evil's: it goes back from one
  ;; that could not attach.
  (roost--evil-state 'roost-ghostel-tmux-connecting-mode (or roost-evil-state 'motion))
  (add-hook 'window-buffer-change-functions #'roost-ghostel-tmux--stand-in-shown nil t)
  ;; A tab not on screen can still show it, with tab-bar and perspective.el
  ;; both on: killing the perspective it was shown in leaves it to that tab.
  (add-hook 'kill-buffer-query-functions
            (lambda () (not (and roost-ghostel-tmux--perspective-going
                                 (roost-ghostel-tmux--tab-shows-p (current-buffer)))))
            nil t))

(defun roost-ghostel-tmux-buffer-p ()
  "Whether the current buffer is a terminal of a tmux session.
A pane of ghostel-tmux, live or left by a connection that ended, or a
buffer that stands in for one on its way.  Not a plain Ghostel terminal."
  (or (bound-and-true-p ghostel-tmux-pane-mode)
      (derived-mode-p 'roost-ghostel-tmux-connecting-mode)))


;;; Which session a buffer belongs to

(defvar-local roost-ghostel-tmux--place nil
  "The (HOST SOCKET SESSION) of this controller, pane or stand-in buffer.
ghostel-tmux has no accessor for a session's socket and host.  This file
attached the session, so it notes what it passed: on the controller,
and on each pane, which keeps it once its session is detached.")

(defvar roost-ghostel-tmux--lost (make-hash-table :test #'equal)
  "How often each place whose connection dropped has been tried again.")

(defvar-local roost-ghostel-tmux--was-attached nil
  "Non-nil in a controller whose session's panes have arrived.
Set as each pane is made, see `roost-ghostel-tmux--pane-made': the
attach hook can come later, or never, as ghostel-tmux holds it while a
minibuffer is open and drops it if the client ends meanwhile.")

(defvar-local roost-ghostel-tmux--stand-in nil
  "In a controller, the buffer that stands in for its pane until it arrives.
`ghostel-tmux-attach' returns before any pane is there.  Roost needs a
buffer of the session in the window at once, as tmux-control's terminal
was: it sends the session commands from the window's buffer right after
it connects, and it drops an open whose window shows another session by
the time its host replies.")

(defvar-local roost-ghostel-tmux--stands-in-for nil
  "In a buffer standing in for a pane, the controller it waits for.")

(defvar ghostel-tmux--panes)
(declare-function ghostel-tmux--controller-live-p "ghostel-tmux" ())

(defun roost-ghostel-tmux--attached-p (controller)
  "Whether CONTROLLER is one of `ghostel-tmux-controllers'.
Asked of CONTROLLER alone where ghostel-tmux can be: its list looks
through every buffer, and Roost asks this for each terminal and each
task's status, which with fifty terminals open took seconds a command.
NEEDS: `ghostel-tmux--panes' and `ghostel-tmux--controller-live-p', what
`ghostel-tmux-controllers' tells a controller by; without them, its list."
  (if (and (boundp 'ghostel-tmux--panes) (fboundp 'ghostel-tmux--controller-live-p))
      (and (buffer-live-p controller)
           (with-current-buffer controller
             (and ghostel-tmux--panes (ghostel-tmux--controller-live-p) t)))
    (and (memq controller (ghostel-tmux-controllers)) t)))

(defun roost-ghostel-tmux--controller ()
  "The controller of the current buffer's attached session, or nil.
A pane's, the one a stand-in waits for, or the buffer itself."
  (let ((controller (or (ghostel-tmux-controller) roost-ghostel-tmux--stands-in-for)))
    (and (roost-ghostel-tmux--attached-p controller) controller)))

(defun roost-ghostel-tmux--buffer-place ()
  "The place of the current buffer.
A pane buffer has its controller's, which follows the session the
controller shows, and keeps the last it had once the connection ends."
  (if-let* ((controller (roost-ghostel-tmux--controller))
            (place (buffer-local-value 'roost-ghostel-tmux--place controller)))
      (setq roost-ghostel-tmux--place place)
    roost-ghostel-tmux--place))

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

(defun roost-ghostel-tmux--host-set-p (name variable)
  "Whether a connection-local profile of yours sets VARIABLE for NAME.
NAME is a host as TRAMP dissects it."
  (seq-some (lambda (profile)
              (assq variable (connection-local-get-profile-variables profile)))
            (connection-local-get-profiles
             (list :application 'tramp
                   :protocol (tramp-file-name-method name)
                   :user (tramp-file-name-user name)
                   :machine (tramp-file-name-host name)))))

(defun roost-ghostel-tmux--prepare-host (host)
  "Set up TRAMP and ghostel-tmux for HOST, once, before its first attach.
ghostel-tmux reaches a host's tmux through TRAMP.  With TRAMP's own
processes, on a real host, Roost stalls soon after a task opens: its
pane stays blank and Roost's poll of the host never ends (7 runs of 8
on 2026-11-15).  With direct async processes, which run tmux by an ssh
of its own, it does not, where the host takes a command that long.
And TRAMP's path on the host can leave tmux
out, as where it is a snap: the tmux named is the one a plain ssh
finds, which is how Roost's helper runs it.
TRAMP reads both for the connection, not for the caller, so they hold
for all you do on HOST through TRAMP in this Emacs.  One you have set
for HOST yourself is left as it is."
  (unless (member host roost-ghostel-tmux--prepared-hosts)
    (require 'tramp)
    (let* ((name (tramp-dissect-file-name (format "/ssh:%s:" host)))
           (profile (intern (format "roost-ghostel-tmux-host-%s" host)))
           (said (with-temp-buffer
                   (and (eql 0 (ignore-errors
                                 (call-process "ssh" nil '(t nil) nil "-o" "BatchMode=yes"
                                               "-o" "ConnectTimeout=8" "--" host
                                               "command -v tmux; getconf PIPE_BUF /")))
                        (split-string (buffer-string) "\n" t "[ \t]+"))))
           (tmux (seq-find #'file-name-absolute-p said))
           (longest (seq-some (lambda (line)
                                (and (string-match-p "\\`[0-9]+\\'" line)
                                     (string-to-number line)))
                              said)))
      ;; A host that did not answer is asked again at the next attach.
      (when said
        (push host roost-ghostel-tmux--prepared-hosts))
      (connection-local-set-profile-variables
       profile
       ;; A direct async process is one command line, no longer than the
       ;; host's PIPE_BUF, TRAMP holds: 4096 on Linux, where attaching
       ;; fits, and 512 on macOS, where it does not.
       `(,@(and longest (>= longest 4096)
                (not (roost-ghostel-tmux--host-set-p name 'tramp-direct-async-process))
                '((tramp-direct-async-process . t)))
         ,@(and tmux
                (not (roost-ghostel-tmux--host-set-p name 'ghostel-tmux-program))
                `((ghostel-tmux-program . ,tmux)))))
      (connection-local-set-profiles
       `(:application tramp :machine ,(tramp-file-name-host name)
                      ,@(and (tramp-file-name-user name)
                             (list :user (tramp-file-name-user name))))
       profile))))

(defun roost-ghostel-tmux--socket (host socket)
  "SOCKET on HOST as `ghostel-tmux-attach' takes it: a name, or a path.
On a remote host, the path `roost--remote-tmux-socket-setup' puts
it at, asked of the host once: Roost's helper runs that setup before
tmux, and ghostel-tmux has no command to run first."
  (if (not host)
      socket
    (roost-ghostel-tmux--prepare-host host)
    (or (gethash (cons host socket) roost-ghostel-tmux--socket-paths)
        (let ((default-directory (format "/ssh:%s:" host)))
          (with-temp-buffer
            ;; stdout alone, the record it marks between NULs: what
            ;; a login script or the host writes besides is no part of the
            ;; path, which is kept for as long as Emacs runs.
            (and (eql 0 (process-file
                         "sh" nil '(t nil) nil "-c"
                         (concat roost--remote-tmux-socket-setup
                                 " && printf '\\0roost-socket\\0%s\\0' \"$TMUX_TMPDIR/tmux-$(id -u)/$1\"")
                         "sh" socket))
                 (progn (goto-char (point-max))
                        (re-search-backward "\0roost-socket\0\\(/[^\0]*\\)\0" nil t))
                 (puthash (cons host socket) (match-string 1) roost-ghostel-tmux--socket-paths))))
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
    ;; What stands in for its pane anywhere, as in another frame, or one
    ;; that said an earlier try could not attach, waits for this one, and
    ;; another window opening it waits in one of those.
    (let ((stand-ins (roost-ghostel-tmux--stand-ins place)))
      (with-current-buffer controller
        (setq roost-ghostel-tmux--place place
              roost-ghostel-tmux--stand-in (car stand-ins)))
      (dolist (stand-in stand-ins)
        (with-current-buffer stand-in
          (setq roost-ghostel-tmux--stands-in-for controller))
        (roost-ghostel-tmux--connecting stand-in)))
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
      ;; It may say that an earlier try could not attach.
      (progn (roost-ghostel-tmux--connecting shown)
             shown)
    (let ((buffer (generate-new-buffer (format "*roost-terminal: %s*" (nth 2 place)))))
      (with-current-buffer buffer
        (roost-ghostel-tmux-connecting-mode)
        (setq roost-ghostel-tmux--place place))
      (roost-ghostel-tmux--connecting buffer)
      (run-hook-with-args 'roost-ghostel-tmux-window-buffer-functions buffer)
      buffer)))

(defun roost-ghostel-tmux--say (stand-in text mode)
  "Have the buffer STAND-IN say TEXT, in place of what it said.
Its mode line says MODE."
  (with-current-buffer stand-in
    (setq mode-name mode)
    (force-mode-line-update)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert text "\n"))))

(defun roost-ghostel-tmux--connecting (stand-in)
  "Have the buffer STAND-IN say that its session is connecting."
  (roost-ghostel-tmux--say
   stand-in
   (format "Connecting to %s…" (nth 2 (buffer-local-value 'roost-ghostel-tmux--place stand-in)))
   "Connecting"))

(defun roost-ghostel-tmux--stand-ins (place)
  "The buffers that stand in for the pane of the session at PLACE."
  (seq-filter (lambda (buffer)
                (and (eq (buffer-local-value 'major-mode buffer) 'roost-ghostel-tmux-connecting-mode)
                     (equal (buffer-local-value 'roost-ghostel-tmux--place buffer) place)))
              (buffer-list)))

(defun roost-ghostel-tmux--not-attached (place &optional detached)
  "Have what stands in for the session at PLACE say that no pane is coming.
Its tmux client ended before a pane came, and none is tried again: the
session went, the connection dropped as it attached, or, with DETACHED,
its client left a session it had attached: you or Roost detached it, or
tmux said the session ended.  The buffer says which, and how to leave it or
try again, as tmux-control's terminal says that its connection was lost;
it would otherwise say that it is connecting for good.  The echo area
says so too where a window shows it."
  (let ((session (nth 2 place))
        shown)
    (dolist (stand-in (roost-ghostel-tmux--stand-ins place))
      (with-current-buffer stand-in
        (roost-ghostel-tmux--say
         stand-in
         (concat (format (if detached "Detached from %s." "Could not attach to %s.") session)
                 "\n\n"
                 (substitute-command-keys
                  "Open its task again to try once more, or press \\[quit-window] to go back."))
         (if detached "Detached" "Could not attach")))
      (when (get-buffer-window stand-in t)
        (setq shown t)))
    (when (and shown (not detached))
      (message "Could not attach to %s" session))))

(defun roost-ghostel-tmux--tab-shows-p (stand-in)
  "Whether a tab not on screen, of any frame, shows STAND-IN."
  (let ((name (buffer-name stand-in)))
    (seq-some (lambda (frame)
                ;; As the frame keeps them: asking `tab-bar-tabs' would
                ;; make tabs for a child frame, and rename the current.
                (seq-some (lambda (tab)
                            (and (eq (car tab) 'tab)
                                 (member name (window-state-buffers (alist-get 'ws tab)))))
                          (frame-parameter frame 'tabs)))
              (frame-list))))

(defun roost-ghostel-tmux--kept-p (stand-in)
  "Whether a workspace not on screen shows STAND-IN.
The workspace you opened its task in, and left before the pane came,
shows it when you are back, by its tab or by Roost, and it gives way
then, see `roost-ghostel-tmux--stand-in-shown'.  Killed, the workspace
would show some other buffer in its place.  A tab says which buffers its
windows show; a perspective only which buffers it has, so a stand-in a
perspective has and no longer shows goes at the next open made there."
  (when (roost--workspace-backend)
    ;; Both, as tabs and perspective.el can be on at once.
    (or
     (roost-ghostel-tmux--tab-shows-p stand-in)
     (and (bound-and-true-p persp-mode)
          (fboundp 'perspectives-hash)
          (seq-some (lambda (frame)
                      (let ((current (persp-curr frame)))
                        (seq-some (lambda (perspective)
                                    (and (not (eq perspective current))
                                         (memq stand-in (persp-buffers perspective))))
                                  (hash-table-values (perspectives-hash frame)))))
                    (frame-list))
          t))))

(defun roost-ghostel-tmux--give-way (stand-in pane)
  "Show the buffer PANE in each window that shows STAND-IN, which then goes.
Unless a workspace not on screen shows it, see `roost-ghostel-tmux--kept-p'."
  (dolist (window (get-buffer-window-list stand-in nil t))
    (roost-ghostel-tmux--show-pane pane window))
  (unless (roost-ghostel-tmux--kept-p stand-in)
    (kill-buffer stand-in)))

(defun roost-ghostel-tmux--stand-in-shown (window)
  "Have the pane that has come take the place of the stand-in WINDOW shows.
On `window-buffer-change-functions', in a buffer that stands in for a
pane: as when you are back in the workspace that showed it.  The pane
takes each window that shows the stand-in then, see
`roost-ghostel-tmux--stand-in-gives-way'.  Not from
the hook itself, which runs as the windows are redrawn, before
ghostel-tmux has fitted the pane to its window; nor while you answer a
question, whose end would put the stand-in back."
  (let ((stand-in (window-buffer window)))
    (run-at-time 0 nil #'roost--when-out-of-minibuffer
                 (lambda () (roost-ghostel-tmux--stand-in-gives-way stand-in)))))

(defun roost-ghostel-tmux--stand-in-gives-way (stand-in)
  "Show the pane that has come wherever STAND-IN shows, and let it go.
Also once its window shows another buffer, as when you put one there
while a question held this: no window would show STAND-IN again."
  (when-let* (((buffer-live-p stand-in))
              ((eq (buffer-local-value 'major-mode stand-in) 'roost-ghostel-tmux-connecting-mode))
              (controller (buffer-local-value 'roost-ghostel-tmux--stands-in-for stand-in))
              ((memq controller (ghostel-tmux-controllers)))
              ;; Its own session's still: ghostel-tmux's own command can
              ;; have switched the controller to another since.
              ((equal (buffer-local-value 'roost-ghostel-tmux--place controller)
                      (buffer-local-value 'roost-ghostel-tmux--place stand-in)))
              ;; Nor switched and yet to say so: ghostel-tmux runs the
              ;; hook that moves its place once tmux has listed the session.
              ((let ((session (with-current-buffer controller (ghostel-tmux-session-name))))
                 (or (not session)
                     (equal session (nth 2 (buffer-local-value 'roost-ghostel-tmux--place stand-in))))))
              (pane (roost-ghostel-tmux--pane controller)))
    (roost-ghostel-tmux--give-way stand-in pane)))

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
        (switch-to-buffer stand-in t)
        ;; One of the perspective's buffers, whichever workspaces Roost
        ;; uses: perspective.el leaves one shown with NORECORD out, and a
        ;; perspective left before the pane came would then lose it, see
        ;; `roost-ghostel-tmux--kept-p'.
        (when (and (bound-and-true-p persp-mode) (fboundp 'persp-add-buffer))
          (persp-add-buffer stand-in))))))

(defun roost-ghostel-tmux--sweep-stand-ins ()
  "Kill the stand-ins no window shows whose pane has come or never will.
One a workspace not on screen shows stays, its client live or not: see
`roost-ghostel-tmux--kept-p'.  It tells you, when you are back, that it
connects or could not."
  (dolist (buffer (buffer-list))
    (when (and (eq (buffer-local-value 'major-mode buffer) 'roost-ghostel-tmux-connecting-mode)
               (not (get-buffer-window buffer t)))
      (let ((controller (buffer-local-value 'roost-ghostel-tmux--stands-in-for buffer)))
        (unless (or (roost-ghostel-tmux--kept-p buffer)
                    (and (memq controller (ghostel-tmux-controllers))
                         (equal (buffer-local-value 'roost-ghostel-tmux--place controller)
                                (buffer-local-value 'roost-ghostel-tmux--place buffer))
                         (not (roost-ghostel-tmux--pane controller))))
          (kill-buffer buffer))))))

(defvar roost-ghostel-tmux--sweep-timer nil
  "The timer of the sweep a closed workspace asked for, until it runs.")

(defun roost-ghostel-tmux--workspace-closed (&rest _)
  "Sweep the stand-ins once a tab or perspective has closed.
On `tab-bar-tab-pre-close-functions' and `persp-killed-hook'.  One kept
for the workspace closed has nothing to show it any more.  From a timer:
both run before the workspace goes, its windows still on screen or in
its tab; and out of the minibuffer, whose end can show again a stand-in
covered while a question was open.  Nothing is asked with no stand-in."
  (when (and (not (timerp roost-ghostel-tmux--sweep-timer))
             (seq-some (lambda (buffer)
                         (eq (buffer-local-value 'major-mode buffer)
                             'roost-ghostel-tmux-connecting-mode))
                       (buffer-list)))
    (setq roost-ghostel-tmux--sweep-timer
          (run-at-time 0 nil (lambda ()
                               (setq roost-ghostel-tmux--sweep-timer nil)
                               (roost--when-out-of-minibuffer
                                #'roost-ghostel-tmux--sweep-stand-ins))))))

(defun roost-ghostel-tmux--perspective-killed (kill &rest args)
  "Call KILL with ARGS, keeping the stand-ins a tab shows.
Around `persp-kill', which kills the buffers only the perspective has,
and can stop to ask about one modified; the sweep that follows, from
`persp-killed-hook', lets go of the rest."
  (let ((roost-ghostel-tmux--perspective-going t))
    (apply kill args)))

(add-hook 'tab-bar-tab-pre-close-functions #'roost-ghostel-tmux--workspace-closed)
(add-hook 'persp-killed-hook #'roost-ghostel-tmux--workspace-closed)
(advice-add 'persp-kill :around #'roost-ghostel-tmux--perspective-killed)

(defun roost-ghostel-tmux-connect-or-switch (host socket-name session)
  "Show tmux SESSION from HOST and SOCKET-NAME in the selected window.
A live connection to the session is reused.  The panes a connection
that ended left behind come alive again, as ghostel-tmux does it.
Returns before the pane is there: until tmux reports it the window shows
a buffer that stands in for it."
  (let* ((host (and host (not (string-empty-p host)) host))
         (socket (or socket-name "main"))
         (place (list host socket session))
         (window (selected-window))
         (shown (window-buffer window))
         (controller (roost-ghostel-tmux--find-controller place))
         (pane (and controller (roost-ghostel-tmux--pane controller))))
    (roost-ghostel-tmux--sweep-stand-ins)
    (cond
     (pane
      (roost-ghostel-tmux--show-pane pane window)
      ;; What stood in for it here, in a workspace you had left as it came.
      (when (and (memq shown (roost-ghostel-tmux--stand-ins place))
                 (not (get-buffer-window shown t))
                 (not (roost-ghostel-tmux--kept-p shown)))
        (kill-buffer shown)))
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
      ;; Its panes get the controller when tmux lists them: until then
      ;; they reach it as a stand-in does, for the commands Roost sends
      ;; the session right after this.
      (let ((snapshots (roost-ghostel-tmux--snapshots place))
            (controller (roost-ghostel-tmux--attach place nil)))
        (dolist (snapshot snapshots)
          (when (buffer-live-p snapshot)
            (with-current-buffer snapshot
              (setq roost-ghostel-tmux--stands-in-for controller))))))
     (t
      (let ((stand-in (roost-ghostel-tmux--stand-in-for place shown)))
        (roost-ghostel-tmux--show-stand-in stand-in nil window)
        (condition-case err
            (roost-ghostel-tmux--show-stand-in
             stand-in (roost-ghostel-tmux--attach place t) window)
          ((error quit)
           (if (eq shown stand-in)
               ;; One that said an earlier try could not attach, opened
               ;; again from it: it says so of this one, where it shows.
               (roost-ghostel-tmux--not-attached place)
             (when (and (window-live-p window) (eq (window-buffer window) stand-in)
                        (buffer-live-p shown))
               (set-window-buffer window shown))
             (kill-buffer stand-in))
           (signal (car err) (cdr err)))))))))

(defun roost-ghostel-tmux--follow-session ()
  "Have the current controller's place follow the session it shows, and return it.
ghostel-tmux's own command can switch a controller to another session:
the place is that session's now.
NEEDS: a hook before the switch, to open the session's task in its
workspace instead, as `tmux-control-switch-session-functions' lets
Roost do."
  (when-let* ((place roost-ghostel-tmux--place))
    (when-let* ((session (ghostel-tmux-session-name))
                ((not (equal session (nth 2 place)))))
      ;; What stood in for the session it left has no pane coming, and
      ;; is this controller's no more: its place would follow it.
      (dolist (stand-in (roost-ghostel-tmux--stand-ins place))
        (with-current-buffer stand-in
          (setq roost-ghostel-tmux--stands-in-for nil)))
      ;; Nor is it tried again, should a try of it be due.
      (remhash place roost-ghostel-tmux--lost)
      (roost-ghostel-tmux--not-attached place t)
      (setq place (list (nth 0 place) (nth 1 place) session)
            roost-ghostel-tmux--place place)
      ;; What stands in for the session it shows now, as one an open of
      ;; it could not attach, waits for this controller.
      (let ((controller (current-buffer)))
        (dolist (stand-in (roost-ghostel-tmux--stand-ins place))
          (with-current-buffer stand-in
            (setq roost-ghostel-tmux--stands-in-for controller))
          (roost-ghostel-tmux--connecting stand-in))))
    place))

(defun roost-ghostel-tmux--attached ()
  "Put the session's pane wherever its stand-in shows.
On `ghostel-tmux-attach-hook', in the controller: tmux has listed the
session's windows, and no minibuffer is open, whose closing would put
the stand-in back in its window.  By now every pane tmux still has is
live again: the pane buffers an earlier connection left that are not,
tmux no longer has."
  (when-let* ((place (roost-ghostel-tmux--follow-session)))
    (setq roost-ghostel-tmux--was-attached t)
    (remhash place roost-ghostel-tmux--lost)
    ;; Each of the session's: one of a connection that dropped as it
    ;; attached waits on, for the try that brings this controller.
    (when-let* ((controller (current-buffer))
                (pane (roost-ghostel-tmux--pane controller)))
      (dolist (stand-in (roost-ghostel-tmux--stand-ins place))
        (with-current-buffer stand-in
          (setq roost-ghostel-tmux--stands-in-for controller))
        (roost-ghostel-tmux--give-way stand-in pane))
      (setq roost-ghostel-tmux--stand-in nil))
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
task's session.  So is one on this machine, and one that never
attached: what stands in for its pane says that none is coming.
NEEDS: `ghostel-tmux--detaching' and `ghostel-tmux--closing', to tell a
connection that dropped from a client that was detached or a session
that ended.  The hook could say which."
  (when-let* ((place roost-ghostel-tmux--place))
    (if (and (nth 0 place)
             (not (bound-and-true-p ghostel-tmux--detaching))
             (not (bound-and-true-p ghostel-tmux--closing))
             (or roost-ghostel-tmux--was-attached (gethash place roost-ghostel-tmux--lost)))
        (roost-ghostel-tmux--attach-again place)
      ;; Detached, or its session ended: no try is owed it any more, nor
      ;; is a later attach one of those tries.
      (when (or (bound-and-true-p ghostel-tmux--detaching)
                (bound-and-true-p ghostel-tmux--closing))
        (remhash place roost-ghostel-tmux--lost))
      ;; tmux says that it exits to a client that never attached too, as
      ;; for a session it cannot find: that one could not attach.
      (roost-ghostel-tmux--not-attached
       place (or (bound-and-true-p ghostel-tmux--detaching)
                 (and roost-ghostel-tmux--was-attached
                      (bound-and-true-p ghostel-tmux--closing)))))))

(defun roost-ghostel-tmux--attach-again (place)
  "Try the session at PLACE again after a second, then two, up to thirty.
Eight times, about two and a half minutes: after that, opening the task
attaches it."
  (let ((tries (gethash place roost-ghostel-tmux--lost 0)))
    (cond
     ;; Attaching already, as when you opened its task while the host was
     ;; asked: that try says how it went.  The count stays until it has
     ;; attached, so that its connection dropping is tried again.
     ((roost-ghostel-tmux--find-controller place))
     ((>= tries 8)
      (remhash place roost-ghostel-tmux--lost)
      (roost-ghostel-tmux--not-attached place))
     (t
      (puthash place (1+ tries) roost-ghostel-tmux--lost)
      (run-at-time (min 30 (expt 2 tries)) nil #'roost-ghostel-tmux--try-again place)))))

(defun roost-ghostel-tmux--try-again (place)
  "Attach the session at PLACE if its host answers, else try later.
The host is asked by an ssh of its own first: an attach goes through
TRAMP, which would hold Emacs for as long as a host that is away takes
to time out.  Nothing is tried once the session is attached again, as
when you opened its task, or once none of its panes is left to bring
back, as when Roost has put them away."
  (cond
   ((not (gethash place roost-ghostel-tmux--lost)))
   ;; Attaching already: `roost-ghostel-tmux--attached' forgets the count.
   ((roost-ghostel-tmux--find-controller place))
   ((not (roost-ghostel-tmux--snapshots place))
    (remhash place roost-ghostel-tmux--lost)
    (roost-ghostel-tmux--not-attached place))
   (t
    (make-process
     :name "roost-ghostel-tmux-host-there"
     :command (list "ssh" "-o" "BatchMode=yes" "-o" "ConnectTimeout=5" "--" (nth 0 place) "true")
     :connection-type 'pipe :noquery t
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (if (and (eql 0 (process-exit-status process))
                  ;; Still wanted: not attached, detached or put away
                  ;; while the host was asked.
                  (gethash place roost-ghostel-tmux--lost)
                  (not (roost-ghostel-tmux--find-controller place))
                  (roost-ghostel-tmux--snapshots place))
             (condition-case nil
                 (roost-ghostel-tmux--attach place t)
               (error (roost-ghostel-tmux--attach-again place)))
           (when (gethash place roost-ghostel-tmux--lost)
             (roost-ghostel-tmux--attach-again place)))))))))

(add-hook 'ghostel-tmux-detach-hook #'roost-ghostel-tmux--detached)

(defun roost-ghostel-tmux-disconnect ()
  "Disconnect the current buffer's client, keeping its panes as they were."
  (when-let* ((controller (roost-ghostel-tmux--controller)))
    (ghostel-tmux-detach t controller)))

(defun roost-ghostel-tmux-reconnect ()
  "Connect the session the current buffer showed again, in the selected window.
Attaching makes its sealed pane buffers live again."
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
              ;; Its session's, should ghostel-tmux's own command have
              ;; switched the controller since it attached: the attach
              ;; hook that would say so can be held for a question.
              (place (with-current-buffer controller
                       (prog1 (roost-ghostel-tmux--follow-session)
                         (setq roost-ghostel-tmux--was-attached t)))))
    (setq roost-ghostel-tmux--place place)
    ;; As tmux-control did, `find-file' and the like start in the
    ;; task's worktree, rather than where the attach ran.
    ;; A remote one names its host as the attach did, which ghostel-tmux
    ;; compares to find the pane's server.
    (when-let* ((task (roost-ghostel-tmux--task place))
                (worktree (roost--field task 'worktree))
                (directory (file-name-as-directory worktree))
                (directory (if (nth 0 place)
                               (format "/ssh:%s:%s" (nth 0 place) directory)
                             directory))
                ((or (nth 0 place) (file-directory-p directory))))
      (setq default-directory directory))
    ;; Ghostel puts the buffer's name back at each change of title.
    (setq-local ghostel-buffer-identification-format nil
                mode-line-buffer-identification '((:eval (roost-ghostel-tmux--mode-line-name))))
    (run-hook-with-args 'roost-ghostel-tmux-window-buffer-functions (current-buffer))))

(defvar ghostel-buffer-identification-format)

(defvar roost--tasks)

(defun roost-ghostel-tmux--task (place)
  "The task whose tmux session is at PLACE, or nil.
Nil too for a session several tasks share, from before each had its
own, which is no one's: see `roost--terminal-task'.  The mode line asks
at each redisplay, many times a second while a terminal streams, so
this looks through the tasks as they are kept, without the list in
order that `roost-tasks' makes."
  (let (found (count 0))
    (maphash (lambda (_key task)
               (when (and (equal (roost--field task 'session) (nth 2 place))
                          (equal (roost--field task 'host) (nth 0 place))
                          (equal (roost--field task 'socket) (nth 1 place)))
                 (setq found task count (1+ count))))
             roost--tasks)
    (and (= count 1) found)))

(defun roost-ghostel-tmux--task-name (place)
  "The name of the task whose tmux session is at PLACE, or nil.
See `roost-ghostel-tmux--task'."
  (when-let* ((task (roost-ghostel-tmux--task place)))
    (roost--field task 'name)))

(defun roost-ghostel-tmux--mode-line-name ()
  "Return \"HOST › TASK\" for the mode line of the current pane buffer.
As tmux-control names a terminal by its host and tmux window, in place
of a buffer name that spells out the session and pane.  A session that
is no task's has its own name for the task's."
  (let ((place (roost-ghostel-tmux--buffer-place)))
    (propertize (string-replace
                 "%" "%%"
                 (format "%s › %s" (or (nth 0 place) "local")
                         (or (roost-ghostel-tmux--task-name place) (nth 2 place) "")))
                'face 'mode-line-buffer-id
                'help-echo (buffer-name))))

(add-hook 'ghostel-tmux-pane-mode-hook #'roost-ghostel-tmux--pane-made)

(defun roost-ghostel-tmux-unload-function ()
  "Remove the hooks this file added, for `unload-feature'."
  (remove-hook 'ghostel-tmux-attach-hook #'roost-ghostel-tmux--attached)
  (remove-hook 'ghostel-tmux-detach-hook #'roost-ghostel-tmux--detached)
  (remove-hook 'ghostel-tmux-pane-mode-hook #'roost-ghostel-tmux--pane-made)
  (remove-hook 'tab-bar-tab-pre-close-functions #'roost-ghostel-tmux--workspace-closed)
  (remove-hook 'persp-killed-hook #'roost-ghostel-tmux--workspace-closed)
  (advice-remove 'persp-kill #'roost-ghostel-tmux--perspective-killed)
  (when (timerp roost-ghostel-tmux--sweep-timer)
    (cancel-timer roost-ghostel-tmux--sweep-timer)
    (setq roost-ghostel-tmux--sweep-timer nil))
  ;; And let `unload-feature' go on.
  nil)

(provide 'roost-ghostel-tmux)
;;; roost-ghostel-tmux.el ends here
