;;; roost-test.el --- Tests for roost -*- lexical-binding: t; -*-

;;; Commentary:
;; Pure-logic tests for the registry model and navigation.  No tmux required.

;;; Code:

(require 'ert)
(require 'roost)

(defconst roost-test--registry
  ;; Shaped like `json-read' output with `json-object-type' = alist and
  ;; symbol keys: agents is an alist of (id-symbol . record-alist).
  '((version . 1)
    (agents
     (add-retry
      (status . "running") (task . "add retry logic to the client")
      (worktreePath . "/tmp/repo-agent-worktree-0001") (branch . "side-agent/add-retry")
      (tmuxWindowId . "@2") (tmuxWindowIndex . 1) (updatedAt . "2026-06-06T10:00:00Z"))
     (fix-auth
      (status . "waiting_user") (task . "fix the auth leak")
      (worktreePath . "/tmp/repo-agent-worktree-0002") (branch . "side-agent/fix-auth")
      (tmuxWindowId . "@5") (tmuxWindowIndex . 3) (updatedAt . "2026-06-06T10:05:00Z"))
     (broke
      (status . "crashed") (task . "rewrite the parser")
      (worktreePath . "/tmp/repo-agent-worktree-0003") (branch . "side-agent/broke")
      (tmuxWindowId . "@9") (tmuxWindowIndex . 5) (updatedAt . "2026-06-06T10:02:00Z"))))
  "A synthetic three-agent registry.")

(defun roost-test--agents ()
  (roost--parse-registry roost-test--registry))

(ert-deftest roost-test-parse-sorts-by-window-index ()
  (let ((agents (roost-test--agents)))
    (should (equal (mapcar #'roost-agent-id agents) '("add-retry" "fix-auth" "broke")))
    (should (equal (mapcar #'roost-agent-window-index agents) '(1 3 5)))
    (let ((fix (nth 1 agents)))
      (should (equal (roost-agent-status fix) "waiting_user"))
      (should (equal (roost-agent-branch fix) "side-agent/fix-auth"))
      (should (equal (roost-agent-worktree fix) "/tmp/repo-agent-worktree-0002"))
      (should (equal (roost-agent-window-id fix) "@5")))))

(ert-deftest roost-test-waiting-agents-filters-by-status ()
  (let* ((agents (roost-test--agents))
         (waiting (roost-waiting-agents agents)))
    ;; waiting_user + crashed qualify; running does not.
    (should (equal (mapcar #'roost-agent-id waiting) '("fix-auth" "broke")))))

(ert-deftest roost-test-next-after-cycles-and-wraps ()
  (let ((waiting (roost-waiting-agents (roost-test--agents)))) ; fix-auth(3), broke(5)
    (should (equal (roost-agent-id (roost--next-after waiting nil)) "fix-auth"))   ; none active
    (should (equal (roost-agent-id (roost--next-after waiting 1)) "fix-auth"))     ; before first
    (should (equal (roost-agent-id (roost--next-after waiting 3)) "broke"))        ; advance
    (should (equal (roost-agent-id (roost--next-after waiting 5)) "fix-auth"))     ; wrap
    (should (equal (roost-agent-id (roost--next-after waiting 9)) "fix-auth"))))   ; past end → wrap

(ert-deftest roost-test-glyph-name ()
  (let ((agents (roost-test--agents)))
    (should (equal (roost--glyph-name (nth 0 agents)) "▸ add-retry"))   ; running
    (should (equal (roost--glyph-name (nth 1 agents)) "◆ fix-auth"))    ; waiting_user
    (should (equal (roost--glyph-name (nth 2 agents)) "☠ broke"))))     ; crashed

(ert-deftest roost-test-tmux-quote ()
  (should (equal (roost--tmux-quote "◆ fix-auth") "\"◆ fix-auth\""))
  ;; double-quote, backslash, $ and backtick are escaped
  (should (equal (roost--tmux-quote "a\"b") "\"a\\\"b\""))
  (should (equal (roost--tmux-quote "x$y`z") "\"x\\$y\\`z\"")))

(ert-deftest roost-test-empty-registry ()
  (should (null (roost--parse-registry '((version . 1) (agents)))))
  (should (null (roost-waiting-agents nil)))
  (should (null (roost--next-after nil nil))))

(provide 'roost-test)
;;; roost-test.el ends here
