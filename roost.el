;;; roost.el --- Cockpit for tmux agent fleets, over tmux-control -*- lexical-binding: t; -*-

;; Author: Clay Sheaff
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes, tmux, agents
;; URL: https://github.com/csheaff/roost

;;; Commentary:

;; Roost is the perch from which you watch and direct a flock of coding
;; agents.  Background agent frameworks that drive tmux -- notably
;; `pi-side-agents' -- run each agent in its own tmux window and git worktree
;; and record their lifecycle in a small registry.  Roost reads that registry
;; and, leaning on `tmux-control' to render the tmux session, turns watching
;; into acting:
;;
;;   - `roost-status'        a dashboard of every agent (status, elapsed, diff)
;;   - `roost-next-waiting'  jump to the next agent that wants you
;;   - `roost-review'        magit on the agent's worktree (review/merge)
;;   - `roost-merge-retire'  merge the agent's branch and tear it down
;;   - `roost-send'          re-steer an agent by sending it a prompt
;;   - `roost-dispatch'      kick off a new agent from Emacs
;;   - `roost-watch-mode'    reflect status into tmux window names (glyphs),
;;                           notify when an agent starts waiting, keep the
;;                           dashboard live
;;
;; Roost touches tmux-control through only two seams -- the tmux window (its
;; index, and its name) -- so tmux-control stays completely agent-agnostic.
;; The contract with the framework is its registry file; `pi-side-agents' is
;; the reference producer.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'tabulated-list)
(require 'iso8601)
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
`roost-next-waiting' cycles over agents in these statuses, and
`roost-watch-mode' notifies when an agent enters one of them."
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

(define-obsolete-variable-alias 'roost-glyph-interval 'roost-watch-interval "0.2")
(defcustom roost-watch-interval 3
  "Seconds between `roost-watch-mode' registry syncs."
  :type 'number)

(defcustom roost-reflect-glyphs t
  "When non-nil, `roost-watch-mode' reflects agent status into tmux window names."
  :type 'boolean)

(defcustom roost-notify t
  "When non-nil, `roost-watch-mode' fires an OS notification when an agent
enters a `roost-wait-statuses' status (it finished its turn, failed, or
crashed)."
  :type 'boolean)

(defcustom roost-notify-function nil
  "Function of (TITLE BODY) used for notifications, or nil for the default.
The default tries terminal-notifier, then macOS osascript, then
`notifications-notify', then a minibuffer message."
  :type '(choice (const :tag "Default" nil) function))

(defcustom roost-base-branches '("main" "master")
  "Candidate base branch names that agents branched from.
The first that exists is used for diffstats and as the merge target."
  :type '(repeat string))

(defcustom roost-dispatch-command "/agent %s"
  "Command sent to the orchestrator pane by `roost-dispatch'.
%s is replaced by the task text.  The default is the `pi-side-agents'
slash command."
  :type 'string)

;;;; Registry model ----------------------------------------------------------

(cl-defstruct (roost-agent (:constructor roost--make-agent) (:copier nil))
  id status task worktree branch window-id window-index started updated)

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
Sorted by tmux window index ascending.  Pure: no I/O, for testing."
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
                       :started (alist-get 'startedAt rec)
                       :updated (alist-get 'updatedAt rec)))
     #'< :key (lambda (a) (or (roost-agent-window-index a) most-positive-fixnum)))))

(defvar roost--retired (make-hash-table :test 'equal)
  "Set of agent ids roost has retired or killed this session.
Filtered out of `roost-agents' so a retired agent does not linger as a ghost
\"crashed\" row once the framework's poll notices its window is gone.")

(defun roost-agents (&optional dir)
  "Return the agents in DIR's repository registry as `roost-agent' structs.
DIR defaults to `roost-directory', then `default-directory'.  Agents roost
has retired this session are excluded."
  (let ((path (roost-registry-path (or dir roost-directory))))
    (when (and path (file-readable-p path))
      (let ((json-object-type 'alist)
            (json-array-type 'list)
            (json-key-type 'symbol))
        (seq-remove (lambda (a) (gethash (roost-agent-id a) roost--retired))
                    (roost--parse-registry (ignore-errors (json-read-file path))))))))

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

;;;; git + formatting helpers -------------------------------------------------

(defun roost--git (dir &rest args)
  "Run git with ARGS in DIR; return trimmed stdout, or nil on non-zero exit."
  (when (and dir (file-directory-p dir))
    (with-temp-buffer
      (when (eq 0 (apply #'process-file "git" nil t nil "-C" dir args))
        (string-trim (buffer-string))))))

(defun roost--base-branch (dir)
  "Return the first of `roost-base-branches' that exists in DIR's repo, or nil."
  (seq-find (lambda (b) (roost--git dir "rev-parse" "--verify" "--quiet"
                                    (concat "refs/heads/" b)))
            roost-base-branches))

(defun roost--parse-shortstat (s)
  "Turn a git --shortstat line S into a compact \"Nf +X -Y\" string, or nil.
Pure, for testing."
  (when (and s (not (string-empty-p s)))
    (let ((files (and (string-match "\\([0-9]+\\) files? changed" s)
                      (match-string 1 s)))
          (ins (and (string-match "\\([0-9]+\\) insertion" s) (match-string 1 s)))
          (del (and (string-match "\\([0-9]+\\) deletion" s) (match-string 1 s))))
      (string-trim
       (concat (and files (format "%sf " files))
               (and ins (format "+%s " ins))
               (and del (format "-%s" del)))))))

(defun roost--diffstat (agent)
  "Return a compact diffstat of AGENT's worktree against its base branch, or nil."
  (let ((wt (roost-agent-worktree agent)))
    (when (and wt (file-directory-p wt))
      (when-let* ((base (roost--base-branch wt)))
        (roost--parse-shortstat (roost--git wt "diff" "--shortstat" base))))))

(defun roost--format-duration (seconds)
  "Format SECONDS as a compact duration like 9s, 4m, 1h12m.  Pure."
  (let ((s (max 0 (floor seconds))))
    (cond ((< s 60) (format "%ds" s))
          ((< s 3600) (format "%dm" (/ s 60)))
          (t (format "%dh%02dm" (/ s 3600) (/ (% s 3600) 60))))))

(defun roost--elapsed (agent)
  "Return the human elapsed time since AGENT started, or \"?\"."
  (let ((start (roost-agent-started agent)))
    (or (and start
             (ignore-errors
               (roost--format-duration
                (- (float-time) (float-time (encode-time (iso8601-parse start)))))))
        "?")))

(defun roost--status-face (agent)
  "Return a face symbol for AGENT's status."
  (pcase (roost-agent-status agent)
    ("waiting_user" 'warning)
    ("done" 'success)
    ((or "failed" "crashed") 'error)
    ("running" 'font-lock-keyword-face)
    (_ 'shadow)))

;;;; tmux-control glue -------------------------------------------------------

(defun roost--cockpit-buffer ()
  "Return the tmux-control buffer to drive, or nil.
Prefers the current buffer when it is a live tmux-control session, else the
first live session."
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

(defun roost--send-to-window (cockpit session index text)
  "Send TEXT then Enter as input to SESSION's window INDEX via COCKPIT."
  (with-current-buffer cockpit
    (let ((target (format "%s:%s" session index)))
      (tmux-control--send-command
       (format "send-keys -t %s -l -- %s" target (roost--tmux-quote text)))
      (tmux-control--send-command (format "send-keys -t %s Enter" target)))))

;;;; Agent selection ---------------------------------------------------------

(defun roost--agent-at-window (agents cockpit)
  "Return the agent in AGENTS occupying COCKPIT's active window, or nil."
  (when cockpit
    (let ((idx (roost--current-window-index cockpit)))
      (and idx (seq-find (lambda (a) (equal (roost-agent-window-index a) idx)) agents)))))

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

(defun roost--pick (agents prompt)
  "Return the agent at the active window, else prompt over AGENTS with PROMPT."
  (or (roost--agent-at-window agents (roost--cockpit-buffer))
      (roost--read-agent agents prompt)))

;;;; Commands: navigate ------------------------------------------------------

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

;;;; Commands: act -----------------------------------------------------------

;;;###autoload
(defun roost-review (&optional agent)
  "Open magit on AGENT's git worktree to review and merge its branch.
With no AGENT, use the one in the active window, else prompt.  Falls back to
`dired' when magit is unavailable."
  (interactive)
  (let ((agent (or agent (roost--pick (roost-agents) "Review agent: "))))
    (unless agent (user-error "No agent to review"))
    (let ((wt (roost-agent-worktree agent)))
      (unless (and wt (file-directory-p wt))
        (user-error "Worktree for %s is gone (%s)" (roost-agent-id agent) wt))
      (if (fboundp 'magit-status) (magit-status wt) (dired wt)))))

;;;###autoload
(defun roost-review-next ()
  "Jump to the next waiting agent and open its worktree for review."
  (interactive)
  (roost-next-waiting)
  (when-let* ((a (roost--agent-at-window (roost-agents) (roost--cockpit-buffer))))
    (roost-review a)))

;;;###autoload
(defun roost-send (&optional agent text)
  "Send TEXT to AGENT's pane as input, to re-steer it without leaving Emacs.
With no AGENT, use the one in the active window, else prompt."
  (interactive)
  (let* ((agent (or agent (roost--pick (roost-agents) "Steer agent: ")))
         (text (or text (read-string (format "Send to %s: " (roost-agent-id agent)))))
         (cockpit (roost--require-cockpit))
         (session (buffer-local-value 'tmux-control--session cockpit))
         (index (roost-agent-window-index agent)))
    (when (string-empty-p (string-trim text)) (user-error "Empty message"))
    (unless index (user-error "No tmux window for %s" (roost-agent-id agent)))
    (roost--send-to-window cockpit session index text)
    (message "roost → %s: %s" (roost-agent-id agent) text)))

;;;###autoload
(defun roost-dispatch (task)
  "Kick off a new agent for TASK from the orchestrator pane.
Sends `roost-dispatch-command' (default the `pi-side-agents' /agent command)
to the live view's current pane, so run this while viewing the orchestrator."
  (interactive "sDispatch agent — task: ")
  (when (string-empty-p (string-trim task)) (user-error "Empty task"))
  (let* ((cockpit (roost--require-cockpit))
         (session (buffer-local-value 'tmux-control--session cockpit))
         (idx (or (roost--current-window-index cockpit) 0))
         (line (format roost-dispatch-command task)))
    (roost--send-to-window cockpit session idx line)
    (message "roost dispatched: %s" line)))

;;;###autoload
(defun roost-kill (&optional agent)
  "Kill AGENT's tmux window after confirmation.
With no AGENT, use the one in the active window, else prompt."
  (interactive)
  (let* ((agent (or agent (roost--pick (roost-agents) "Kill agent: ")))
         (cockpit (roost--require-cockpit))
         (session (buffer-local-value 'tmux-control--session cockpit))
         (idx (roost-agent-window-index agent)))
    (when (and idx (yes-or-no-p (format "Kill agent %s (its tmux window)? "
                                        (roost-agent-id agent))))
      (with-current-buffer cockpit
        (tmux-control--send-command (format "kill-window -t %s:%s" session idx)))
      (puthash (roost-agent-id agent) t roost--retired)
      (message "Killed %s" (roost-agent-id agent)))))

;;;###autoload
(defun roost-merge-retire (&optional agent)
  "Merge AGENT's branch into the base branch, then tear the agent down.
Guarded: the repository must be on the base branch with a clean tree; a merge
conflict aborts and points you at `roost-review' (magit) instead of leaving a
half-merged tree.  On success, removes the worktree, deletes the branch, and
kills the tmux window."
  (interactive)
  (let* ((agents (roost-agents))
         (agent (or agent (roost--pick agents "Merge & retire agent: ")))
         (branch (roost-agent-branch agent))
         (repo (roost--git-root (or roost-directory default-directory)))
         (base (and repo (roost--base-branch repo))))
    (unless (and branch repo base)
      (user-error "Missing branch/repo/base for %s" (roost-agent-id agent)))
    (let ((cur (roost--git repo "rev-parse" "--abbrev-ref" "HEAD"))
          ;; Ignore untracked files: the registry lives in an untracked .pi/,
          ;; so only uncommitted *tracked* changes should block a merge.
          (dirty (roost--git repo "status" "--porcelain" "--untracked-files=no")))
      (unless (equal cur base)
        (user-error "%s is on %s, not %s — check out %s first" repo cur base base))
      (when (and dirty (not (string-empty-p dirty)))
        (user-error "%s has uncommitted (tracked) changes; commit or stash first" repo)))
    (unless (yes-or-no-p (format "Merge %s into %s and retire %s? "
                                 branch base (roost-agent-id agent)))
      (user-error "Aborted"))
    ;; Agents (pi-side-agents) leave their work *uncommitted* in the worktree.
    ;; Commit it on the agent's branch first -- staging everything except the
    ;; framework's own .pi/ runtime dir -- so the merge has something to bring
    ;; over and `git worktree remove' can never discard real work.
    (let ((wt (roost-agent-worktree agent)))
      (when (and wt (file-directory-p wt))
        (roost--git wt "add" "-A" "--" ":!.pi" ":!.pi/")
        (unless (roost--git wt "diff" "--cached" "--quiet") ; non-nil = nothing staged
          (roost--git wt "commit" "-m"
                      (format "agent %s: %s" (roost-agent-id agent)
                              (truncate-string-to-width (or (roost-agent-task agent) "") 60))))))
    (let ((ahead (roost--git repo "rev-list" "--count" (format "%s..%s" base branch))))
      (when (or (null ahead) (equal ahead "0"))
        (user-error "%s has no commits to merge into %s — nothing to do" branch base)))
    (roost--git repo "merge" "--no-ff" "-m"
                (format "Merge agent %s" (roost-agent-id agent)) branch)
    (cond
     ;; A merge in progress means there were conflicts: abort, don't retire.
     ((roost--git repo "rev-parse" "-q" "--verify" "MERGE_HEAD")
      (roost--git repo "merge" "--abort")
      (user-error "Merge conflict — resolve with `roost-review' (magit), then merge"))
     ;; Branch is now an ancestor of HEAD: the merge landed.  Tear down.
     ((roost--git repo "merge-base" "--is-ancestor" branch "HEAD")
      (let* ((wt (roost-agent-worktree agent))
             (cockpit (roost--cockpit-buffer))
             (session (and cockpit (buffer-local-value 'tmux-control--session cockpit)))
             (idx (roost-agent-window-index agent)))
        (when (and wt (file-directory-p wt))
          (roost--git repo "worktree" "remove" "--force" wt))
        (roost--git repo "branch" "-D" branch)
        (when (and cockpit session idx)
          (with-current-buffer cockpit
            (tmux-control--send-command (format "kill-window -t %s:%s" session idx))))
        (puthash (roost-agent-id agent) t roost--retired)
        (message "Merged %s into %s and retired %s"
                 branch base (roost-agent-id agent))))
     (t (user-error "Merge did not complete; inspect %s" repo)))))

;;;; Dashboard ---------------------------------------------------------------

(defun roost--dashboard-entries ()
  "Return `tabulated-list-entries' for the current agents."
  (mapcar
   (lambda (a)
     (let ((face (roost--status-face a)))
       (list (roost-agent-id a)
             (vector
              (propertize (or (cdr (assoc (roost-agent-status a) roost-status-glyphs)) " ")
                          'face face)
              (roost-agent-id a)
              (propertize (or (roost-agent-status a) "?") 'face face)
              (roost--elapsed a)
              (format "%s" (or (roost-agent-window-index a) "?"))
              (or (roost--diffstat a) "—")
              (or (roost-agent-branch a) "")
              (truncate-string-to-width (or (roost-agent-task a) "") 60)))))
   (roost-agents)))

(defvar-keymap roost-dashboard-mode-map
  :doc "Keymap for `roost-dashboard-mode'."
  "RET" #'roost-dashboard-jump
  "r"   #'roost-dashboard-review
  "m"   #'roost-dashboard-merge
  "e"   #'roost-dashboard-send
  "k"   #'roost-dashboard-kill
  "d"   #'roost-dispatch
  "g"   #'roost-dashboard-refresh)

(define-derived-mode roost-dashboard-mode tabulated-list-mode "Roost"
  "Major mode for the roost agent dashboard.
\\{roost-dashboard-mode-map}"
  (setq tabulated-list-format
        [(" " 2 t) ("Agent" 18 t) ("Status" 13 t) ("Elapsed" 8 t)
         ("W" 3 t) ("Diff" 11 t) ("Branch" 24 t) ("Task" 0 nil)])
  (setq tabulated-list-entries #'roost--dashboard-entries)
  (setq tabulated-list-sort-key (cons "W" nil))
  (tabulated-list-init-header))

;;;###autoload
(defun roost-status ()
  "Open the roost dashboard: every agent with status, elapsed, and diffstat.
Keys: RET jump, r review, m merge & retire, e send/steer, k kill, d dispatch,
g refresh."
  (interactive)
  (let ((buf (get-buffer-create "*roost*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'roost-dashboard-mode) (roost-dashboard-mode))
      (tabulated-list-print t))
    (pop-to-buffer buf)))

(defun roost--dashboard-agent ()
  "Return the agent on the current dashboard line, or nil."
  (when-let* ((id (tabulated-list-get-id)))
    (seq-find (lambda (a) (equal (roost-agent-id a) id)) (roost-agents))))

(defun roost-dashboard-refresh ()
  "Refresh the dashboard, preserving point."
  (interactive)
  (when (derived-mode-p 'roost-dashboard-mode)
    (let ((line (line-number-at-pos)))
      (tabulated-list-print t)
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun roost--dashboard-refresh-if-live ()
  "Refresh the *roost* dashboard if it exists, without selecting it."
  (when-let* ((buf (get-buffer "*roost*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (derived-mode-p 'roost-dashboard-mode)
          (roost-dashboard-refresh))))))

(defun roost-dashboard-jump ()
  "Switch the live view to the agent on this line."
  (interactive)
  (when-let* ((a (roost--dashboard-agent)) (c (roost--cockpit-buffer)))
    (roost--select c (roost-agent-window-index a))
    (message "roost → %s [%s]" (roost-agent-id a) (roost-agent-status a))))

(defun roost-dashboard-review ()
  "Review the agent on this line (magit on its worktree)."
  (interactive)
  (when-let* ((a (roost--dashboard-agent))) (roost-review a)))

(defun roost-dashboard-merge ()
  "Merge and retire the agent on this line."
  (interactive)
  (when-let* ((a (roost--dashboard-agent))) (roost-merge-retire a) (roost-dashboard-refresh)))

(defun roost-dashboard-send ()
  "Send a prompt to the agent on this line."
  (interactive)
  (when-let* ((a (roost--dashboard-agent))) (roost-send a)))

(defun roost-dashboard-kill ()
  "Kill the agent on this line."
  (interactive)
  (when-let* ((a (roost--dashboard-agent))) (roost-kill a) (roost-dashboard-refresh)))

;;;; Watch mode: glyphs + notifications + dashboard ---------------------------

(defvar roost--status-cache (make-hash-table :test 'equal)
  "Map of agent id -> last status seen, for change detection.")

(defun roost--notify (title body)
  "Show an OS notification with TITLE and BODY (best effort)."
  (cond
   ((functionp roost-notify-function) (funcall roost-notify-function title body))
   ((executable-find "terminal-notifier")
    (call-process "terminal-notifier" nil 0 nil
                  "-title" title "-message" body "-sender" "org.gnu.Emacs"))
   ((eq system-type 'darwin)
    (call-process "osascript" nil 0 nil "-e"
                  (format "display notification %S with title %S" body title)))
   ((fboundp 'notifications-notify)
    (notifications-notify :title title :body body))
   (t (message "%s — %s" title body))))

(defun roost--sync ()
  "Sync from the registry: reflect glyphs, notify on wait, refresh dashboard."
  (let* ((cockpit (roost--cockpit-buffer))
         (session (and cockpit (buffer-local-value 'tmux-control--session cockpit)))
         (agents (roost-agents))
         (ids (mapcar #'roost-agent-id agents)))
    (dolist (agent agents)
      (let* ((id (roost-agent-id agent))
             (status (roost-agent-status agent))
             (index (roost-agent-window-index agent))
             (prev (gethash id roost--status-cache 'none)))
        (unless (equal prev status)
          (when (and roost-reflect-glyphs cockpit session index)
            (roost--rename-window cockpit session index (roost--glyph-name agent)))
          ;; Notify only on a genuine transition into a wait status -- not on
          ;; first sight (so attaching to an existing fleet does not spam).
          (when (and roost-notify (not (eq prev 'none))
                     (member status roost-wait-statuses))
            (roost--notify (format "Agent %s — %s" id status)
                           (truncate-string-to-width (or (roost-agent-task agent) "") 90)))
          (puthash id status roost--status-cache))))
    ;; Drop agents that left the registry.
    (maphash (lambda (k _) (unless (member k ids) (remhash k roost--status-cache)))
             roost--status-cache))
  (roost--dashboard-refresh-if-live))

(defvar roost--watch-timer nil)

;;;###autoload
(define-minor-mode roost-watch-mode
  "Global mode that watches the agent registry.
While on, every `roost-watch-interval' seconds roost reflects each agent's
status into its tmux window name (so tmux-control's tab bar and flock view
show who is running/waiting/failed -- with no change to tmux-control), fires
an OS notification when an agent enters a waiting/failed/crashed status, and
keeps the `roost-status' dashboard up to date."
  :global t
  :lighter " Roost"
  (if roost-watch-mode
      (unless roost--watch-timer
        (setq roost--watch-timer
              (run-with-timer 0 roost-watch-interval #'roost--sync)))
    (when roost--watch-timer
      (cancel-timer roost--watch-timer)
      (setq roost--watch-timer nil))
    (clrhash roost--status-cache)))

;;;###autoload
(define-obsolete-function-alias 'roost-glyph-mode 'roost-watch-mode "0.2")

(provide 'roost)
;;; roost.el ends here
