;;; roost.el --- Cockpit for tmux agent fleets, over tmux-control -*- lexical-binding: t; -*-

;; Author: Clay Sheaff
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes, tmux, agents
;; URL: https://github.com/csheaff/roost

;;; Commentary:

;; Roost is the perch from which you watch and direct a flock of coding
;; agents.  Background agent frameworks that drive tmux -- notably
;; `pi-side-agents' -- run each agent in its own tmux window and git worktree
;; and record their lifecycle in a small registry.  Roost reads that registry
;; and, leaning entirely on `tmux-control' to render the tmux session as Emacs
;; buffers, turns watching into acting:
;;
;;   - `roost-next-waiting' jumps the live view to the next agent that wants you
;;     (finished its turn, failed, or crashed).
;;   - `roost-review' opens magit on the agent's worktree, so you review and
;;     merge its branch with your normal tools -- in the same Emacs.
;;   - `roost-list' picks any agent by status/task and jumps to it.
;;   - `roost-dispatch' kicks off a new agent from Emacs.
;;   - `roost-glyph-mode' reflects each agent's status into its tmux window
;;     name (a leading glyph), so tmux-control's tab bar and flock view light
;;     up with who-is-doing-what -- no change to tmux-control, which simply
;;     renders the names.
;;
;; Roost knows nothing tmux-control-specific beyond a couple of entry points,
;; and tmux-control knows nothing about agents: the contract between them is
;; the tmux window (its index, and its name).  The contract with the framework
;; is its registry file; `pi-side-agents' is the reference producer.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'tmux-control nil t)

(declare-function tmux-control-select-window "tmux-control" (&optional index))
(declare-function tmux-control--send-command "tmux-control" (command &optional kind))
(declare-function tmux-control--live-session-buffers "tmux-control" ())
(defvar tmux-control--session)
(defvar tmux-control--current-window)
(declare-function magit-status "magit-status" (&optional directory cache))

(defgroup roost nil
  "Cockpit for tmux agent fleets, rendered through tmux-control."
  :group 'tools
  :prefix "roost-")

(defcustom roost-registry-relative-path ".pi/side-agents/registry.json"
  "Path of the agent registry, relative to the repository root.
The default matches `pi-side-agents'."
  :type 'string)

(defcustom roost-directory nil
  "Repository whose agent registry roost reads.
A tmux-control buffer keeps its `default-directory' local, which is not
necessarily the fleet's repository, so set this to the repo where your agents
run (it is resolved to its git top-level).  Nil falls back to
`default-directory'."
  :type '(choice (const :tag "Use default-directory" nil) directory))

(defcustom roost-wait-statuses '("waiting_user" "failed" "crashed")
  "Agent statuses that mean an agent wants your attention.
`roost-next-waiting' cycles over agents in these statuses."
  :type '(repeat string))

(defcustom roost-status-glyphs
  '(("allocating_worktree" . "•")
    ("spawning_tmux"       . "•")
    ("running"             . "▸")
    ("waiting_user"        . "◆")
    ("done"                . "✓")
    ("failed"              . "✗")
    ("crashed"            . "☠"))
  "Glyph shown at the start of an agent's tmux window name, per status."
  :type '(alist :key-type string :value-type string))

(defcustom roost-glyph-interval 3
  "Seconds between `roost-glyph-mode' refreshes of tmux window names."
  :type 'number)

(defcustom roost-dispatch-command "/agent %s"
  "Command sent to the orchestrator pane by `roost-dispatch'.
%s is replaced by the task text.  The default is the `pi-side-agents'
slash command."
  :type 'string)

;;;; Registry model ----------------------------------------------------------

(cl-defstruct (roost-agent (:constructor roost--make-agent) (:copier nil))
  id status task worktree branch window-id window-index updated)

(defun roost--git-root (&optional dir)
  "Return the git top-level directory for DIR, or nil if none."
  (let ((default-directory (or dir default-directory)))
    (when-let* ((root (ignore-errors
                        (string-trim
                         (shell-command-to-string
                          "git rev-parse --show-toplevel 2>/dev/null")))))
      (and (not (string-empty-p root)) (file-name-as-directory root)))))

(defun roost-registry-path (&optional dir)
  "Return the registry file path for DIR's repository, or nil."
  (when-let* ((root (roost--git-root dir)))
    (expand-file-name roost-registry-relative-path root)))

(defun roost--parse-registry (data)
  "Turn parsed registry DATA (an alist) into a list of `roost-agent'.
Sorted by tmux window index ascending, so navigation order matches the tab
bar.  Pure: no I/O, for testing."
  (let ((agents (alist-get 'agents data)))
    (cl-sort
     (cl-loop for cell in agents
              for rec = (cdr cell)
              collect (roost--make-agent
                       :id (symbol-name (car cell))
                       :status (alist-get 'status rec)
                       :task (alist-get 'task rec)
                       :worktree (alist-get 'worktreePath rec)
                       :branch (alist-get 'branch rec)
                       :window-id (alist-get 'tmuxWindowId rec)
                       :window-index (alist-get 'tmuxWindowIndex rec)
                       :updated (alist-get 'updatedAt rec)))
     #'< :key (lambda (a) (or (roost-agent-window-index a) most-positive-fixnum)))))

(defun roost-agents (&optional dir)
  "Return the agents in DIR's repository registry as `roost-agent' structs.
DIR defaults to `roost-directory', then `default-directory'."
  (let ((path (roost-registry-path (or dir roost-directory))))
    (when (and path (file-readable-p path))
      (let ((json-object-type 'alist)
            (json-array-type 'list)
            (json-key-type 'symbol))
        (roost--parse-registry (ignore-errors (json-read-file path)))))))

(defun roost-waiting-agents (agents)
  "Return the subset of AGENTS whose status is in `roost-wait-statuses'."
  (seq-filter (lambda (a) (member (roost-agent-status a) roost-wait-statuses))
              agents))

(defun roost--next-after (agents index)
  "Return the first of AGENTS with window index greater than INDEX, wrapping.
AGENTS is assumed sorted by window index ascending.  INDEX may be nil."
  (or (and index
           (seq-find (lambda (a) (and (roost-agent-window-index a)
                                      (> (roost-agent-window-index a) index)))
                     agents))
      (car agents)))

(defun roost--glyph-name (agent)
  "Return the tmux window name for AGENT: its status glyph plus its id."
  (let ((glyph (or (cdr (assoc (roost-agent-status agent) roost-status-glyphs)) "")))
    (string-trim (concat glyph " " (roost-agent-id agent)))))

;;;; tmux-control glue -------------------------------------------------------

(defun roost--cockpit-buffer ()
  "Return the tmux-control buffer to drive, or nil.
Prefers the current buffer when it is a live tmux-control session, else the
single live session, else the first one."
  (cond
   ((and (boundp 'tmux-control--session) tmux-control--session (current-buffer)))
   ((not (fboundp 'tmux-control--live-session-buffers)) nil)
   (t (car (tmux-control--live-session-buffers)))))

(defun roost--require-cockpit ()
  "Return a live cockpit buffer or signal a `user-error'."
  (or (roost--cockpit-buffer)
      (user-error "No live tmux-control session; connect one first")))

(defun roost--tmux-quote (s)
  "Quote S as a single tmux command-line argument (double-quoted)."
  (concat "\"" (replace-regexp-in-string "\\([\"\\$`]\\)" "\\\\\\1" s) "\""))

(defun roost--current-window-index (cockpit)
  "Return COCKPIT's currently active tmux window index as a number, or nil."
  (with-current-buffer cockpit
    (and (boundp 'tmux-control--current-window)
         tmux-control--current-window
         (string-to-number tmux-control--current-window))))

(defun roost--select (cockpit index)
  "Switch COCKPIT's live view to tmux window INDEX."
  (when index
    (with-current-buffer cockpit
      (tmux-control-select-window index))))

(defun roost--rename-window (cockpit session index name)
  "Rename SESSION's window INDEX to NAME over COCKPIT's control connection."
  (with-current-buffer cockpit
    (tmux-control--send-command
     (format "rename-window -t %s:%s %s" session index (roost--tmux-quote name)))))

;;;; Commands ----------------------------------------------------------------

(defun roost--agent-at-window (agents cockpit)
  "Return the agent in AGENTS occupying COCKPIT's active window, or nil."
  (let ((idx (roost--current-window-index cockpit)))
    (and idx (seq-find (lambda (a) (equal (roost-agent-window-index a) idx)) agents))))

(defun roost--read-agent (agents prompt)
  "Choose an agent from AGENTS with completion under PROMPT."
  (let ((choices (mapcar (lambda (a)
                           (cons (format "%-13s w%-3s %s  %s"
                                         (or (roost-agent-status a) "?")
                                         (or (roost-agent-window-index a) "?")
                                         (roost-agent-id a)
                                         (truncate-string-to-width
                                          (or (roost-agent-task a) "") 54))
                                 a))
                         agents)))
    (cdr (assoc (completing-read prompt choices nil t) choices))))

;;;###autoload
(defun roost-next-waiting ()
  "Switch the live view to the next agent that wants your attention.
Cycles, by tmux window order, over agents whose status is in
`roost-wait-statuses' (finished a turn, failed, or crashed)."
  (interactive)
  (let* ((cockpit (roost--require-cockpit))
         (waiting (roost-waiting-agents (roost-agents))))
    (unless waiting (user-error "No agents are waiting"))
    (let ((next (roost--next-after waiting (roost--current-window-index cockpit))))
      (roost--select cockpit (roost-agent-window-index next))
      (message "roost → %s [%s]" (roost-agent-id next) (roost-agent-status next)))))

;;;###autoload
(defun roost-list ()
  "Pick an agent by status/task and switch the live view to it."
  (interactive)
  (let* ((cockpit (roost--require-cockpit))
         (agents (roost-agents)))
    (unless agents (user-error "No agents in the registry"))
    (let ((agent (roost--read-agent agents "Agent: ")))
      (when agent
        (roost--select cockpit (roost-agent-window-index agent))
        (message "roost → %s [%s]" (roost-agent-id agent) (roost-agent-status agent))))))

;;;###autoload
(defun roost-review (&optional agent)
  "Open magit on AGENT's git worktree to review and merge its branch.
With no AGENT, use the one in the active window, else prompt.  Falls back to
`dired' when magit is unavailable."
  (interactive)
  (let* ((agents (roost-agents))
         (agent (or agent
                    (roost--agent-at-window agents (roost--cockpit-buffer))
                    (roost--read-agent agents "Review agent: "))))
    (unless agent (user-error "No agent to review"))
    (let ((wt (roost-agent-worktree agent)))
      (unless (and wt (file-directory-p wt))
        (user-error "Worktree for %s is gone (%s)" (roost-agent-id agent) wt))
      (if (fboundp 'magit-status)
          (magit-status wt)
        (dired wt)))))

;;;###autoload
(defun roost-dispatch (task)
  "Kick off a new agent for TASK from the orchestrator pane.
Sends `roost-dispatch-command' (default the `pi-side-agents' /agent command)
as input to the live view's current pane, so run this while viewing the
orchestrator agent."
  (interactive "sDispatch agent — task: ")
  (when (string-empty-p (string-trim task))
    (user-error "Empty task"))
  (let* ((cockpit (roost--require-cockpit))
         (line (format roost-dispatch-command task)))
    (with-current-buffer cockpit
      (let ((target (format "%s:%s" tmux-control--session
                            (or tmux-control--current-window "0"))))
        (tmux-control--send-command
         (format "send-keys -t %s -l -- %s" target (roost--tmux-quote line)))
        (tmux-control--send-command (format "send-keys -t %s Enter" target))))
    (message "roost dispatched: %s" line)))

;;;; Glyph reflection --------------------------------------------------------

(defvar roost--glyph-cache (make-hash-table :test 'equal)
  "Map of agent id -> last status reflected into its tmux window name.")

(defun roost--reflect-glyphs ()
  "Reflect each agent's status into its tmux window name, on change only."
  (when-let* ((cockpit (roost--cockpit-buffer)))
    (let ((agents (roost-agents))
          (session (buffer-local-value 'tmux-control--session cockpit)))
      (when session
        (dolist (agent agents)
          (let ((id (roost-agent-id agent))
                (status (roost-agent-status agent))
                (index (roost-agent-window-index agent)))
            (when (and index (not (equal (gethash id roost--glyph-cache) status)))
              (puthash id status roost--glyph-cache)
              (roost--rename-window cockpit session index (roost--glyph-name agent)))))))))

(defvar roost--glyph-timer nil)

;;;###autoload
(define-minor-mode roost-glyph-mode
  "Global mode reflecting agent status into tmux window names.
While on, every `roost-glyph-interval' seconds each tracked agent's tmux
window is renamed with a leading status glyph, so tmux-control's tab bar and
flock view show who is running, waiting, or failed at a glance."
  :global t
  :lighter " Roost"
  (if roost-glyph-mode
      (unless roost--glyph-timer
        (setq roost--glyph-timer
              (run-with-timer 0 roost-glyph-interval #'roost--reflect-glyphs)))
    (when roost--glyph-timer
      (cancel-timer roost--glyph-timer)
      (setq roost--glyph-timer nil))
    (clrhash roost--glyph-cache)))

(provide 'roost)
;;; roost.el ends here
