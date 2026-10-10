;;; roost-reader.el --- Read a coding agent's session, typeset -*- lexical-binding: t; -*-

;; A prototype.  It reads a Claude Code session log (the JSON lines
;; Claude Code writes under ~/.claude/projects) and shows the session as
;; a typeset conversation: prose in a serif face with its Markdown
;; rendered, code blocks highlighted, tool calls folded to one line, and
;; diagrams drawn where the agent showed them with the show_diagram
;; tool of prototype/roost_diagram_mcp.py: SVG natively, Mermaid and
;; HTML in an embedded web view.  It follows the log as it grows.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'seq)
(require 'cl-lib)
(require 'xml)
(require 'text-property-search)
(require 'xwidget nil t)

(declare-function roost--choose "roost" (&optional task))
(declare-function roost--field "roost" (task field))
(declare-function roost--host-directory "roost" (host path))
(declare-function xwidget-webkit-goto-uri "xwidget" (xwidget uri))
(declare-function xwidget-webkit-execute-script "xwidget" (xwidget script &optional callback))
(declare-function xwidget-resize "xwidget.c" (xwidget new-width new-height))
(declare-function xwidget-put "xwidget.c" (xwidget propname value))
(declare-function xwidget-size-request "xwidget.c" (xwidget))
(declare-function xwidget-live-p "xwidget.c" (object))
(declare-function xwidget-insert "xwidget" (pos type title width height &optional args related))

(defgroup roost-reader nil
  "Read a coding agent's session, typeset."
  :group 'roost)

(defcustom roost-reader-serif "Charter"
  "Family for prose."
  :type 'string)

(defcustom roost-reader-mono "Menlo"
  "Family for code and tool calls."
  :type 'string)

(defcustom roost-reader-measure 70
  "Width of the reading column, in characters of prose."
  :type 'natnum)

(defcustom roost-reader-inline-html nil
  "Whether interactive HTML diagrams show inline in an embedded web view.
On macOS, Emacs does not clip an embedded web view to its window, so
one scrolled near an edge draws over the header and mode lines; by
default such a diagram opens in a window of its own instead."
  :type 'boolean)

(defface roost-reader-prose `((t :family ,roost-reader-serif :height 165)) "Prose.")
(defface roost-reader-h1 `((t :family ,roost-reader-serif :weight bold :height 1.45)) "Level 1 heading.")
(defface roost-reader-h2 `((t :family ,roost-reader-serif :weight bold :height 1.25)) "Level 2 heading.")
(defface roost-reader-h3 `((t :family ,roost-reader-serif :weight bold :height 1.1)) "Level 3 heading.")
(defface roost-reader-bold '((t :weight bold)) "Strong emphasis.")
(defface roost-reader-italic '((t :slant italic)) "Emphasis.")
(defface roost-reader-inline-code
  `((((background dark)) :family ,roost-reader-mono :height 0.85 :background "#2b2e36")
    (t :family ,roost-reader-mono :height 0.85 :background "#eceae4"))
  "Inline code.")
(defface roost-reader-code
  `((((background dark)) :family ,roost-reader-mono :height 0.85 :background "#22252c" :extend t)
    (t :family ,roost-reader-mono :height 0.85 :background "#f3f1ec" :extend t))
  "Code blocks.")
(defface roost-reader-bullet '((t :inherit shadow)) "List markers.")
(defface roost-reader-quote '((t :inherit shadow :slant italic)) "Block quotes.")
(defface roost-reader-rule '((t :inherit shadow :strike-through t)) "Horizontal rules.")
(defface roost-reader-user
  '((((background dark)) :background "#1d2a24" :extend t)
    (t :background "#eaf3ec" :extend t))
  "Your prompts.")
(defface roost-reader-tool
  `((t :inherit shadow :family ,roost-reader-mono :height 0.8))
  "A tool call's one-line summary.")
(defface roost-reader-tool-failed
  `((t :inherit error :family ,roost-reader-mono :height 0.8))
  "A tool call that failed.")
(defface roost-reader-detail
  `((((background dark)) :family ,roost-reader-mono :height 0.78 :foreground "#a9adb6" :background "#202228" :extend t)
    (t :family ,roost-reader-mono :height 0.78 :foreground "#55585e" :background "#f6f5f1" :extend t))
  "A tool call's details, unfolded.")
(defface roost-reader-diagram-title
  `((t :inherit shadow :family ,roost-reader-serif :slant italic :height 0.9))
  "A diagram's title.")
(defface roost-reader-note '((t :inherit shadow :slant italic)) "Notes about the session.")

;;;; Reading the log

(defvar-local roost-reader--file nil "The session log shown.")
(defvar-local roost-reader--offset 0 "Bytes of the log read so far.")
(defvar-local roost-reader--tools nil "Tool calls by id: (SUMMARY-MARKER DETAILS-END SYMBOL).")
(defvar-local roost-reader--timer nil "Timer following the log.")
(defvar-local roost-reader--turns 0 "Prompts shown.")

(defun roost-reader--read-new ()
  "Entries appended to the log since the last read, as alists."
  (let* ((file roost-reader--file)
         (offset roost-reader--offset)
         (size (file-attribute-size (file-attributes file))))
    (when (and size (> size offset))
      (let ((text (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally file nil offset size)
                    ;; Only whole lines; a line still being written waits.
                    (goto-char (point-max))
                    (skip-chars-backward "^\n")
                    (setq offset (+ offset (1- (point))))
                    (decode-coding-string (buffer-substring-no-properties (point-min) (point)) 'utf-8))))
        (setq roost-reader--offset offset)
        (delq nil (mapcar (lambda (line)
                            (ignore-errors
                              (json-parse-string line :object-type 'alist :array-type 'list
                                                 :null-object nil :false-object nil)))
                          (split-string text "\n" t)))))))

;;;; Markdown

(defun roost-reader--insert-inline (text)
  "Insert TEXT with its inline Markdown rendered."
  (let ((start 0)
        (pattern (concat "\\*\\*\\(.+?\\)\\*\\*"          ; 1 bold
                         "\\|`\\([^`\n]+\\)`"               ; 2 code
                         "\\|\\[\\([^]\n]+\\)\\](\\([^)\n]+\\))" ; 3 4 link
                         "\\|\\(?:^\\|[^*[:alnum:]]\\)\\*\\([^* \n][^*\n]*?\\)\\*"  ; 5 italic
                         "\\|\\(?:^\\|[^_[:alnum:]]\\)_\\([^_ \n][^_\n]*?\\)_\\(?:[^_[:alnum:]]\\|$\\)"))) ; 6
    (while (string-match pattern text start)
      (let ((whole-start (match-beginning 0)))
        (cond ((match-beginning 1)
               (let ((inner (match-string 1 text))
                     (end (match-end 0)))
                 (insert (substring text start whole-start))
                 (let ((from (point)))
                   ;; Bold text may hold code or a link of its own.
                   (roost-reader--insert-inline inner)
                   (add-face-text-property from (point) 'roost-reader-bold))
                 (set-match-data (list whole-start end))))
              ((match-beginning 2)
               (insert (substring text start whole-start)
                       (propertize (match-string 2 text) 'face 'roost-reader-inline-code)))
              ((match-beginning 3)
               (insert (substring text start whole-start))
               (let ((url (match-string 4 text)))
                 (insert-text-button (match-string 3 text) 'action (lambda (_) (browse-url url))
                                     'follow-link t 'help-echo url)))
              (t
               (let ((group (if (match-beginning 5) 5 6)))
                 ;; Up to the opening delimiter, which is dropped.
                 (insert (substring text start (1- (match-beginning group))))
                 (insert (propertize (match-string group text) 'face 'roost-reader-italic))
                 (when (and (= group 6) (< (match-beginning group) (match-end 0))
                            (> (match-end 0) (1+ (match-end group))))
                   (insert (substring text (1+ (match-end group)) (match-end 0)))))))
        (setq start (match-end 0))))
    (insert (substring text start))))

(defun roost-reader--paragraph-break ()
  "Leave one blank line before what is inserted next, unless one is there."
  (unless (or (bobp) (and (eq (char-before) ?\n) (eq (char-before (1- (point))) ?\n)))
    (insert (if (eq (char-before) ?\n) "\n" "\n\n"))))

(defconst roost-reader--modes
  '(("emacs-lisp" . emacs-lisp-mode) ("elisp" . emacs-lisp-mode) ("lisp" . lisp-mode)
    ("python" . python-mode) ("py" . python-mode) ("sh" . sh-mode) ("bash" . sh-mode)
    ("shell" . sh-mode) ("console" . sh-mode) ("zsh" . sh-mode) ("js" . js-mode)
    ("javascript" . js-mode) ("ts" . typescript-ts-mode) ("json" . js-json-mode)
    ("c" . c-mode) ("diff" . diff-mode) ("ruby" . ruby-mode) ("go" . go-ts-mode)
    ("rust" . rust-ts-mode) ("css" . css-mode) ("html" . mhtml-mode) ("toml" . conf-toml-mode)
    ("yaml" . yaml-ts-mode) ("sql" . sql-mode) ("org" . org-mode) ("markdown" . text-mode))
  "Major modes that highlight code blocks, by language name.")

(defun roost-reader--fontify (code language)
  "CODE highlighted as LANGUAGE, if Emacs has a mode for it."
  (let ((mode (cdr (assoc (downcase (or language "")) roost-reader--modes))))
    (if (not (and mode (fboundp mode)))
        code
      (with-temp-buffer
        (insert code)
        ;; Without your mode hooks: no servers start for a code block.
        (delay-mode-hooks (ignore-errors (funcall mode)))
        (ignore-errors (font-lock-ensure))
        (buffer-string)))))

(defun roost-reader--insert-code (code language)
  "Insert CODE, a block in LANGUAGE."
  (let ((start (point)))
    (insert (roost-reader--fontify (string-trim-right code) language) "\n")
    (add-face-text-property start (point) 'roost-reader-code t)
    (add-text-properties start (point) '(line-prefix "  " wrap-prefix "  "))))

(defface roost-reader-table-rule
  '((((background dark)) :underline (:color "#3b3f48" :position 8))
    (t :underline (:color "#d9d5ca" :position 8)))
  "The line under a table row.")

(defun roost-reader--table-cells (line)
  "The cells of the Markdown table row LINE."
  (mapcar #'string-trim
          (split-string (replace-regexp-in-string "\\`\\s-*|\\||\\s-*\\'" "" line) "|")))

(defun roost-reader--rendered-inline (text)
  "TEXT with its inline Markdown rendered, as a string."
  (with-temp-buffer (roost-reader--insert-inline text) (buffer-string)))

(defun roost-reader--insert-table (lines)
  "Insert the Markdown table LINES with its columns aligned.
A table too wide for the column is shown as written."
  (let* ((rows (mapcar (lambda (line) (mapcar #'roost-reader--rendered-inline
                                              (roost-reader--table-cells line)))
                       (seq-remove (lambda (line) (string-match-p "\\`[ \t|:-]+\\'" line)) lines)))
         (width (lambda (cell bold)
                  (let ((cell (copy-sequence cell)))
                    (when bold (add-face-text-property 0 (length cell) 'roost-reader-bold t cell))
                    ;; Measured in the prose face, as the reader shows it.
                    (add-face-text-property 0 (length cell) 'roost-reader-prose t cell)
                    (string-pixel-width cell))))
         (count (apply #'max (mapcar #'length rows)))
         (gap (* 2 (string-pixel-width (propertize "n" 'face 'roost-reader-prose))))
         (widths (mapcar (lambda (i)
                           (apply #'max (seq-map-indexed (lambda (row n)
                                                           (funcall width (or (nth i row) "") (= n 0)))
                                                         rows)))
                         (number-sequence 0 (1- count))))
         (stops (let ((x 0)) (mapcar (lambda (w) (setq x (+ x w gap))) widths))))
    (if (> (car (last stops)) (roost-reader--column-pixels))
        (roost-reader--insert-stacked-table rows)
      (seq-do-indexed
       (lambda (row n)
         (let ((start (point)))
           (seq-do-indexed (lambda (cell i)
                             (insert (if (= n 0) (propertize cell 'face 'roost-reader-bold) cell)
                                     (propertize " " 'display `(space :align-to (,(nth i stops))))))
                           row)
           (when (< n (1- (length rows)))
             (add-face-text-property start (point) 'roost-reader-table-rule t))
           (insert "\n")))
       rows))))

(defun roost-reader--insert-stacked-table (rows)
  "Insert the table ROWS, too wide for the column, one row after another.
Each row's first cell heads it, and its other cells follow, named by
their column."
  (let ((header (car rows)))
    (dolist (row (cdr rows))
      (insert (propertize (or (car row) "") 'face 'roost-reader-bold) "\n")
      (seq-do-indexed (lambda (cell i)
                        (let ((start (point)))
                          (insert "  " (propertize (or (nth (1+ i) header) "") 'face 'roost-reader-note)
                                  " — " cell "\n")
                          (put-text-property start (point) 'wrap-prefix "    ")))
                      (cdr row)))))

(defun roost-reader--insert-markdown (text)
  "Insert TEXT, Markdown, rendered."
  (let ((lines (split-string text "\n")) code language table)
    (cl-flet ((flush-table ()
                (when table
                  (roost-reader--insert-table (nreverse table))
                  (setq table nil))))
      (dolist (line lines)
        (cond
         ((string-match "^ *```\\(.*\\)$" line)
          (if code
              (progn (roost-reader--insert-code (string-join (nreverse (cdr code)) "\n") language)
                     (setq code nil language nil))
            (flush-table)
            (setq code (list t) language (string-trim (match-string 1 line)))))
         (code (push line (cdr code)))
         ((string-match "^ *|" line) (push line table))
         (t
          (flush-table)
          (cond
           ((string-match "^\\(#+\\) +\\(.*\\)$" line)
            (let ((level (length (match-string 1 line))))
              (insert (propertize (match-string 2 line) 'face
                                  (pcase level (1 'roost-reader-h1) (2 'roost-reader-h2) (_ 'roost-reader-h3)))
                      "\n")))
           ((string-match "^\\( *\\)\\([-*+]\\|[0-9]+[.)]\\) +\\(.*\\)$" line)
            (let* ((indent (match-string 1 line))
                   (marker (match-string 2 line))
                   (bullet (if (string-match-p "[0-9]" marker) (concat marker " ") "•  "))
                   (prefix (concat "  " indent (make-string (length bullet) ?\s)))
                   (start (point)))
              (insert "  " indent (propertize bullet 'face 'roost-reader-bullet))
              (roost-reader--insert-inline (match-string 3 line))
              (insert "\n")
              (put-text-property start (point) 'wrap-prefix prefix)))
           ((string-match "^> ?\\(.*\\)$" line)
            (let ((start (point)))
              (roost-reader--insert-inline (match-string 1 line))
              (insert "\n")
              (add-face-text-property start (point) 'roost-reader-quote)
              (add-text-properties start (point) '(line-prefix "│ " wrap-prefix "│ "))))
           ((string-match "^ *\\(---+\\|\\*\\*\\*+\\) *$" line)
            (insert (propertize (make-string 30 ?\s) 'face 'roost-reader-rule) "\n"))
           (t (roost-reader--insert-inline line) (insert "\n"))))))
      (when code
        (roost-reader--insert-code (string-join (nreverse (cdr code)) "\n") language))
      (flush-table))))

;;;; Tool calls

(defun roost-reader--short (text &optional width)
  "TEXT on one line, within WIDTH characters."
  (truncate-string-to-width (replace-regexp-in-string "[ \t\n]+" " " (string-trim (or text "")))
                            (or width 90) nil nil "…"))

(defun roost-reader--tool-summary (name input &optional state)
  "One line saying what tool NAME did with INPUT.
STATE `failed' says what it tried instead; any other non-nil STATE, what
it is doing."
  (let* ((file (file-name-nondirectory (or (alist-get 'file_path input) (alist-get 'path input) "")))
         (say (lambda (forms &optional what)
                ;; FORMS: doing, done, tried.
                (cond ((eq state 'failed) (concat (nth 2 forms) what))
                      (state (concat (nth 0 forms) what "…"))
                      (t (concat (nth 1 forms) what))))))
    (pcase name
      ("Bash" (concat "$ " (roost-reader--short (or (alist-get 'description input)
                                                    (alist-get 'command input)))))
      ("Read" (funcall say '("Reading " "Read " "Read ") file))
      ((or "Edit" "MultiEdit" "NotebookEdit") (funcall say '("Editing " "Edited " "Edit ") file))
      ("Write" (funcall say '("Writing " "Wrote " "Write ") file))
      ((or "Grep" "Glob") (funcall say '("Searching for " "Searched for " "Search for ")
                                   (roost-reader--short (or (alist-get 'pattern input) "") 60)))
      ("WebFetch" (funcall say '("Fetching " "Fetched " "Fetch ") (roost-reader--short (alist-get 'url input) 70)))
      ("WebSearch" (funcall say '("Searching the web for " "Searched the web for " "Search the web for ")
                            (roost-reader--short (alist-get 'query input) 60)))
      ((or "Task" "Agent") (funcall say '("Asking an agent: " "Asked an agent: " "Ask an agent: ")
                                    (roost-reader--short (alist-get 'description input) 60)))
      ("TodoWrite" (funcall say '("Updating its to-do list" "Updated its to-do list" "Update its to-do list")))
      ("AskUserQuestion" (funcall say '("Asking you: " "Asked you: " "Ask you: ")
                                  (roost-reader--short
                                   (alist-get 'question (car (alist-get 'questions input))) 70)))
      ("ExitPlanMode" (funcall say '("Proposing a plan" "Proposed a plan" "Propose a plan")))
      ("ToolSearch" (funcall say '("Loading tools" "Loaded tools" "Load tools")))
      (_ (concat name (when-let* ((first (cdar input)) ((stringp first)))
                        (concat " " (roost-reader--short first 60))))))))

(defun roost-reader--line-diff (old new)
  "The lines that differ between OLD and NEW, as `diff -U1' shows them.
Hunks are set apart by a line of \"⋯\".  Without the diff program, every
line of OLD is removed and every line of NEW added."
  (let* ((inhibit-message t)
         (a (make-temp-file "roost-old-" nil nil (concat old "\n")))
         (b (make-temp-file "roost-new-" nil nil (concat new "\n"))))
    (unwind-protect
        (with-temp-buffer
          (if (memq (ignore-errors (call-process "diff" nil t nil "-U1" a b)) '(0 1))
              (progn
                (goto-char (point-min))
                ;; The file names, then each hunk's line numbers.
                (delete-region (point) (progn (forward-line 2) (point)))
                (while (re-search-forward "^@@.*@@.*$" nil t)
                  (replace-match "⋯" t t))
                (goto-char (point-min))
                (when (looking-at "⋯\n") (replace-match ""))
                ;; Blank lines of context, at either end, say nothing.
                (string-trim (buffer-string) "\\(?: *\n\\)+" "\\(?:\n *\\)+"))
            (concat (replace-regexp-in-string "^" "-" old) "\n" (replace-regexp-in-string "^" "+" new))))
      (delete-file a)
      (delete-file b))))

(defun roost-reader--edit-diff (input)
  "The change an edit tool's INPUT makes, as the lines it removes and adds."
  (mapconcat (lambda (edit)
               (roost-reader--line-diff (or (alist-get 'old_string edit) "")
                                        (or (alist-get 'new_string edit) "")))
             (or (alist-get 'edits input) (list input))
             "\n⋯\n"))

(defface roost-reader-added
  `((((background dark)) :family ,roost-reader-mono :height 0.85
     :foreground "#b9e4c4" :background "#1c3125" :extend t)
    (t :family ,roost-reader-mono :height 0.85 :foreground "#1d5a31" :background "#e4f3e8" :extend t))
  "Lines an edit adds.")

(defface roost-reader-removed
  `((((background dark)) :family ,roost-reader-mono :height 0.85
     :foreground "#f0bcc0" :background "#382226" :extend t)
    (t :family ,roost-reader-mono :height 0.85 :foreground "#7b2630" :background "#f9e4e6" :extend t))
  "Lines an edit removes.")

(defun roost-reader--insert-diff (diff)
  "Insert DIFF, from `roost-reader--edit-diff', its lines tinted."
  (dolist (line (split-string diff "\n"))
    (let ((start (point)))
      (insert line "\n")
      (add-face-text-property start (point)
                              (pcase (string-to-char line)
                                (?+ 'roost-reader-added)
                                (?- 'roost-reader-removed)
                                (_ 'roost-reader-code)))
      (add-text-properties start (point) '(line-prefix "  " wrap-prefix "  ")))))

(defun roost-reader--tool-details (name input)
  "What tool NAME was given, INPUT, as text to unfold."
  (pcase name
    ("Bash" (alist-get 'command input))
    ((or "Edit" "MultiEdit")
     (concat (alist-get 'file_path input) "\n" (roost-reader--edit-diff input)))
    ("Write" (concat (alist-get 'file_path input) "\n"
                     (truncate-string-to-width (or (alist-get 'content input) "") 1500 nil nil "\n…")))
    (_ (string-trim (json-encode input)))))

(defun roost-reader--result-text (content)
  "A tool result's CONTENT as text."
  (cond ((stringp content) content)
        ((listp content)
         (mapconcat (lambda (block)
                      (pcase (alist-get 'type block)
                        ("text" (alist-get 'text block))
                        ("tool_reference" (concat "→ " (alist-get 'tool_name block)))
                        (other (format "[%s]" other))))
                    content "\n"))
        (t "")))

(defun roost-reader--clip (text lines)
  "TEXT cut to its first LINES lines."
  (let ((all (split-string (string-trim-right (or text "")) "\n")))
    (if (length> all lines)
        (concat (string-join (seq-take all lines) "\n")
                (format "\n… %d more lines" (- (length all) lines)))
      (string-join all "\n"))))

(defun roost-reader--insert-tool (block)
  "Insert the tool call BLOCK, folded."
  (let* ((id (alist-get 'id block))
         (name (alist-get 'name block))
         (input (alist-get 'input block)))
    (if (string-suffix-p "show_diagram" name)
        (roost-reader--insert-diagram input)
      ;; A run of tool calls sits together, set off from the prose.
      (unless (get-text-property (max (point-min) (1- (point))) 'roost-reader-tool-end)
        (roost-reader--paragraph-break))
      (let ((symbol (intern (format "roost-reader-%s" id)))
            (summary-start (point)))
        (insert (propertize (concat "▸ " (roost-reader--tool-summary name input t))
                            'face 'roost-reader-tool 'roost-reader-fold symbol
                            'mouse-face 'highlight 'help-echo "RET or mouse-1: show what it did"))
        ;; The details hang off the summary's line, before its newline, so a
        ;; folded call leaves nothing on the next line.
        (let ((details-start (point)))
          (insert "\n" (roost-reader--clip (roost-reader--tool-details name input) 40))
          (let ((end (copy-marker (point) nil)))
            (add-text-properties details-start (point) (list 'invisible symbol 'face 'roost-reader-detail
                                                             'line-prefix "    " 'wrap-prefix "    "))
            (insert (propertize "\n" 'roost-reader-tool-end t))
            (add-to-invisibility-spec symbol)
            (push (cons id (list (copy-marker summary-start) end symbol
                                 (roost-reader--tool-summary name input)
                                 (roost-reader--tool-summary name input 'failed)))
                  roost-reader--tools)))))))

(defun roost-reader--attach-result (block)
  "Add the tool result BLOCK to its call's details."
  (when-let* ((entry (cdr (assoc (alist-get 'tool_use_id block) roost-reader--tools))))
    (pcase-let ((`(,summary ,end ,symbol ,done ,failed) entry))
      (save-excursion
        ;; It has happened, or failed: say so.
        (goto-char (+ summary 2))
        (let ((properties (text-properties-at (point))))
          (delete-region (point) (line-end-position))
          (insert (apply #'propertize (if (alist-get 'is_error block) failed done) properties)))
        (goto-char end)
        (let ((start (point)))
          (insert "\n→ " (roost-reader--clip (roost-reader--result-text (alist-get 'content block)) 30))
          (add-text-properties start (point) (list 'invisible symbol 'face 'roost-reader-detail
                                                   'line-prefix "    " 'wrap-prefix "    "))
          (set-marker end (point)))
        (when (alist-get 'is_error block)
          (goto-char summary)
          (add-face-text-property (point) (line-end-position) 'roost-reader-tool-failed))))))

(defun roost-reader-toggle ()
  "Show or hide what the tool call at point did."
  (interactive)
  (when-let* ((symbol (get-text-property (line-beginning-position) 'roost-reader-fold)))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (line-beginning-position))
        (if (memq symbol (if (listp buffer-invisibility-spec) buffer-invisibility-spec))
            (progn (remove-from-invisibility-spec symbol) (roost-reader--set-arrow "▾"))
          (add-to-invisibility-spec symbol) (roost-reader--set-arrow "▸"))))))

(defun roost-reader--set-arrow (arrow)
  "Replace the fold arrow on this line with ARROW."
  (let ((properties (text-properties-at (point))))
    (delete-char 1)
    (insert (apply #'propertize arrow properties))))

;;;; Diagrams

(defun roost-reader--column-pixels ()
  "Width of the reading column in pixels."
  (let ((window (get-buffer-window nil t)))
    (min (if window (window-body-width window t) 900)
         (* roost-reader-measure (string-pixel-width (propertize "n" 'face 'roost-reader-prose))))))

(defun roost-reader--insert-diagram (input)
  "Insert the diagram the agent showed with INPUT."
  (let ((title (alist-get 'title input))
        (format (alist-get 'format input))
        (code (or (alist-get 'code input) "")))
    (roost-reader--paragraph-break)
    (pcase format
      ("svg" (roost-reader--insert-svg code))
      ("mermaid" (roost-reader--insert-mermaid code))
      ("html" (if roost-reader-inline-html
                  (roost-reader--insert-web format code)
                (roost-reader--insert-html-button title code)))
      (_ (roost-reader--insert-code code nil)))
    (when title (insert (propertize title 'face 'roost-reader-diagram-title) "\n"))
    (insert "\n")))

(defun roost-reader--insert-svg (code)
  "Insert the SVG CODE as an image the width of the column."
  (let ((image (ignore-errors
                 (create-image code 'svg t :width (- (roost-reader--column-pixels) 16)
                               :background "#fbfaf7" :margin 8 :ascent 'center))))
    (if image
        (progn (insert-image image "[diagram]") (insert "\n"))
      (insert (propertize "The diagram's SVG could not be drawn.\n" 'face 'roost-reader-note)))))

(defun roost-reader--insert-html-button (title code)
  "Insert a button opening the interactive HTML diagram CODE, named TITLE."
  (insert-text-button (concat "◆ " (or title "Interactive diagram") " — open it")
                      'face 'roost-reader-diagram-title 'follow-link t
                      'help-echo "Open this interactive diagram in a web view"
                      'action (lambda (_)
                                (let ((file (let ((inhibit-message t))
                                              (make-temp-file "roost-reader-" nil ".html"
                                                              (roost-reader--web-page "html" code)))))
                                  (if (fboundp 'xwidget-webkit-browse-url)
                                      (xwidget-webkit-browse-url (concat "file://" file))
                                    (browse-url (concat "file://" file))))))
  (insert "\n"))

(defun roost-reader--insert-mermaid (code)
  "Insert the Mermaid diagram CODE, drawn off screen, as a native SVG image.
Without an embedded web engine, the code is shown instead."
  (if (not (fboundp 'make-xwidget))
      (roost-reader--insert-code code "mermaid")
    (let ((placeholder (copy-marker (point)))
          (reader (current-buffer)))
      (insert (propertize "Drawing the diagram…\n" 'face 'roost-reader-note))
      (roost-reader--render-mermaid
       code
       (lambda (svg)
         (when (buffer-live-p reader)
           (with-current-buffer reader
             (let ((inhibit-read-only t))
               (save-excursion
                 (goto-char placeholder)
                 (delete-region (point) (line-beginning-position 2))
                 (if (string-prefix-p "<svg" svg)
                     ;; Mermaid sets each word of a label apart; keep the
                     ;; spaces between them, which librsvg would drop.
                     (roost-reader--insert-svg
                      (replace-regexp-in-string "<text " "<text xml:space=\"preserve\" " svg t t))
                   (roost-reader--insert-code code "mermaid")))))))))))

(defun roost-reader--render-mermaid (code callback)
  "Draw Mermaid CODE in a hidden web view, then call CALLBACK with its SVG.
Labels are drawn as SVG text, which Emacs can show, not as HTML."
  (let* ((buffer (generate-new-buffer " *roost-reader-mermaid*"))
         (page (concat "<!doctype html><meta charset=utf-8><body><script type=module>"
                       "import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';"
                       "mermaid.initialize({startOnLoad:false,theme:'neutral',htmlLabels:false,"
                       "flowchart:{htmlLabels:false}});"
                       "mermaid.render('diagram'," (json-encode code) ")"
                       ".then(r=>{document.body.innerHTML=r.svg;"
                       "const svg=document.querySelector('svg'),b=svg.getBBox(),m=12;"
                       ;; Fit the drawing's own bounds, with a margin, as Emacs scales it.
                       "svg.setAttribute('viewBox',[b.x-m,b.y-m,b.width+2*m,b.height+2*m].join(' '));"
                       "svg.removeAttribute('style');svg.setAttribute('width',b.width+2*m);"
                       "svg.setAttribute('height',b.height+2*m);window.svgOut=svg.outerHTML})"
                       ".catch(e=>{window.svgOut='ERROR '+e});"
                       "</script></body>"))
         (file (let ((inhibit-message t)) (make-temp-file "roost-reader-" nil ".html" page)))
         (tries 0)
         xwidget timer)
    (with-current-buffer buffer
      (roost-reader--no-xwidget-query)
      (insert " ")
      (setq xwidget (xwidget-insert (point-min) 'webkit "mermaid" 800 600)))
    (xwidget-put xwidget 'callback #'roost-reader--web-loaded)
    (xwidget-webkit-goto-uri xwidget (concat "file://" file))
    (setq timer
          (run-with-timer
           0.5 0.5
           (lambda ()
             (setq tries (1+ tries))
             (if (or (> tries 40) (not (xwidget-live-p xwidget)))
                 (progn (cancel-timer timer) (kill-buffer buffer) (funcall callback ""))
               (xwidget-webkit-execute-script
                xwidget "window.svgOut || ''"
                (lambda (svg)
                  (when (and (stringp svg) (not (string-empty-p svg)) (timerp timer))
                    (cancel-timer timer)
                    (setq timer nil)
                    (when (buffer-live-p buffer) (kill-buffer buffer))
                    (funcall callback svg))))))))))

(defun roost-reader--web-page (format code)
  "A web page showing CODE, Mermaid or HTML per FORMAT."
  (if (equal format "mermaid")
      (concat "<!doctype html><meta charset=utf-8><body style='margin:0;padding:12px;background:#fbfaf7'>"
              "<pre class=mermaid>" (xml-escape-string code) "</pre>"
              "<script type=module>import mermaid from "
              "'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';"
              "mermaid.initialize({startOnLoad:true,theme:'neutral'});</script></body>")
    (if (string-match-p "<html\\|<body" code)
        code
      (concat "<!doctype html><meta charset=utf-8><body style='margin:0;padding:12px;"
              "background:#fbfaf7;font-family:-apple-system,sans-serif'>" code "</body>"))))

(defun roost-reader--insert-web (format code)
  "Insert an embedded web view showing CODE in FORMAT."
  (if (not (fboundp 'make-xwidget))
      (roost-reader--insert-code code format)
    (let* ((file (let ((inhibit-message t))
                   (make-temp-file "roost-reader-" nil ".html" (roost-reader--web-page format code))))
           (width (roost-reader--column-pixels))
           (xwidget (progn (insert "#")
                           (xwidget-insert (1- (point)) 'webkit "roost diagram" width 360))))
      (goto-char (point-max))
      (insert "\n")
      (xwidget-put xwidget 'callback #'roost-reader--web-loaded)
      (xwidget-webkit-goto-uri xwidget (concat "file://" file)))))

(defun roost-reader--web-loaded (xwidget type)
  "Handle XWIDGET's event of TYPE: run script callbacks, fit the page once loaded.
Emacs delivers a script's result as an event to the view's callback."
  (pcase type
    ('javascript-callback
     (let ((function (nth 3 last-input-event)))
       (when (functionp function) (funcall function (nth 4 last-input-event)))))
    ('load-changed
     (when (equal (nth 3 last-input-event) "load-finished")
       ;; Mermaid draws after the load; measure a moment later.
       (run-at-time 0.8 nil #'roost-reader--fit-web xwidget)))))

(defun roost-reader--fit-web (xwidget)
  "Make XWIDGET as tall as its page."
  (when (xwidget-live-p xwidget)
    (xwidget-webkit-execute-script
     xwidget "document.documentElement.scrollHeight"
     (lambda (height)
       (when (and (numberp height) (xwidget-live-p xwidget))
         (xwidget-resize xwidget (car (xwidget-size-request xwidget))
                         (min 900 (max 120 (round height)))))))))

;;;; Rendering entries

(defun roost-reader--user-text-p (text)
  "Whether TEXT is something you wrote, not a command wrapper."
  (and (stringp text) (not (string-blank-p text))
       (not (string-match-p "\\`\\s-*<" text))
       (not (string-prefix-p "Caveat:" text))))

(defun roost-reader--insert-prompt (text)
  "Insert TEXT, a prompt you sent, as a tinted block set off to the right."
  (setq roost-reader--turns (1+ roost-reader--turns))
  (roost-reader--paragraph-break)
  (let ((start (point)))
    (roost-reader--insert-markdown (string-trim text))
    (add-face-text-property start (point) 'roost-reader-user t)
    (put-text-property start (point) 'roost-reader-prompt t)
    (let ((indent (make-string 6 ?\s)))
      (add-text-properties start (point) (list 'line-prefix indent 'wrap-prefix indent))))
  (insert "\n"))

(defun roost-reader--insert-entry (entry)
  "Insert the log ENTRY, if it is part of the conversation."
  (let ((message (alist-get 'message entry)))
    (when (and (listp message) (not (alist-get 'isSidechain entry)) (not (alist-get 'isMeta entry)))
      (let ((content (alist-get 'content message)))
        (pcase (alist-get 'type entry)
          ("user"
           (if (stringp content)
               (when (roost-reader--user-text-p content) (roost-reader--insert-prompt content))
             (dolist (block content)
               (pcase (alist-get 'type block)
                 ("tool_result" (roost-reader--attach-result block))
                 ("text" (let ((text (alist-get 'text block)))
                           (cond ((string-prefix-p "[Request interrupted" text)
                                  (insert (propertize "You stopped Claude.\n" 'face 'roost-reader-note)))
                                 ((roost-reader--user-text-p text) (roost-reader--insert-prompt text)))))))))
          ("assistant"
           (dolist (block content)
             (pcase (alist-get 'type block)
               ("text" (roost-reader--paragraph-break)
                (roost-reader--insert-markdown (string-trim (alist-get 'text block))))
               ("tool_use" (roost-reader--insert-tool block))))))))))

(defun roost-reader--append ()
  "Insert what the log has gained, keeping a window at the end there."
  (when-let* ((entries (roost-reader--read-new)))
    (let* ((inhibit-read-only t)
           (windows (seq-filter (lambda (window) (>= (window-point window) (1- (point-max))))
                                (get-buffer-window-list nil nil t))))
      (save-excursion
        (goto-char (point-max))
        (mapc #'roost-reader--insert-entry entries))
      (dolist (window windows)
        (set-window-point window (point-max)))
      (roost-reader--header))))

(defun roost-reader--header ()
  "Name the session in the header line."
  (setq header-line-format
        (format "  %s · %d prompt%s%s" (file-name-base roost-reader--file) roost-reader--turns
                (if (= roost-reader--turns 1) "" "s")
                (if (timerp roost-reader--timer) " · following" ""))))

;;;; The reader

(defun roost-reader--fit-column (&optional window)
  "Center the reading column in the windows showing WINDOW's reader."
  (dolist (window (get-buffer-window-list (if (windowp window) (window-buffer window) (current-buffer))
                                          nil t))
    (let* ((text (roost-reader--column-pixels))
           (spare (max 0 (- (window-pixel-width window) text)))
           (columns (/ spare 2 (frame-char-width (window-frame window)))))
      (set-window-margins window columns columns))))

(defun roost-reader--release-margins (window &rest _)
  "Let WINDOW split: the reading windows in it give up their margins.
Emacs counts margins in a window's least width, so a centered column
would refuse every split; `roost-reader--fit-column' sets them again for
the new sizes."
  (let ((windows (list window)) live)
    (while windows
      (let ((next (pop windows)))
        (if (window-live-p next)
            (push next live)
          (let ((child (window-child next)))
            (while child
              (push child windows)
              (setq child (window-next-sibling child)))))))
    (dolist (live live)
      (when (with-current-buffer (window-buffer live)
              (memq 'roost-reader--fit-column window-size-change-functions))
        (set-window-margins live 0 0)))))

(advice-add 'split-window :before #'roost-reader--release-margins)

(defun roost-reader--no-xwidget-query ()
  "Let this buffer be killed without asking about its web views.
The question is a global hook, so this buffer gets its own list without it."
  (setq-local kill-buffer-query-functions
              (remq 'xwidget-kill-buffer-query-function
                    (default-value 'kill-buffer-query-functions))))

(defvar-keymap roost-reader-mode-map
  :parent special-mode-map
  "RET" #'roost-reader-toggle
  "TAB" #'roost-reader-toggle
  "<mouse-1>" #'roost-reader-toggle-at-click
  "n" #'roost-reader-next-prompt
  "p" #'roost-reader-previous-prompt
  "f" #'roost-reader-follow
  "g" #'roost-reader-reload)

(define-derived-mode roost-reader-mode special-mode "Roost Reader"
  "A coding agent's session, typeset.
\\{roost-reader-mode-map}"
  (buffer-face-set 'roost-reader-prose)
  (setq-local line-spacing 0.3
              truncate-lines nil
              word-wrap t
              buffer-invisibility-spec (list t)
              cursor-type 'bar)
  (visual-line-mode 1)
  ;; Global line numbers come on after the mode starts; keep them off.
  (add-hook 'after-change-major-mode-hook
            (lambda () (when (bound-and-true-p display-line-numbers-mode) (display-line-numbers-mode -1)))
            90 t)
  ;; Its web views go with it, without asking.
  (roost-reader--no-xwidget-query)
  (add-hook 'window-size-change-functions #'roost-reader--fit-column nil t)
  (add-hook 'kill-buffer-hook #'roost-reader--stop nil t))

(defun roost-reader-toggle-at-click (event)
  "Toggle the tool call clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (roost-reader-toggle))

(defun roost-reader-next-prompt ()
  "Move to your next prompt."
  (interactive)
  (when-let* ((next (text-property-search-forward 'roost-reader-prompt t t)))
    (goto-char (prop-match-beginning next))
    (recenter 2)))

(defun roost-reader-previous-prompt ()
  "Move to your previous prompt."
  (interactive)
  (goto-char (line-beginning-position))
  (when-let* ((previous (text-property-search-backward 'roost-reader-prompt t t)))
    (goto-char (prop-match-beginning previous))
    (recenter 2)))

(defun roost-reader--stop ()
  "Stop following the log."
  (when (timerp roost-reader--timer) (cancel-timer roost-reader--timer))
  (setq roost-reader--timer nil))

(defun roost-reader-follow (&optional arg)
  "Follow the log as the agent works; with ARG negative, stop."
  (interactive "P")
  (roost-reader--stop)
  (unless (and arg (< (prefix-numeric-value arg) 0))
    (let ((buffer (current-buffer)) timer)
      (setq timer (run-with-timer 1.5 1.5 (lambda ()
                                            (if (buffer-live-p buffer)
                                                (with-current-buffer buffer
                                                  (with-demoted-errors "Roost reader: %S" (roost-reader--append)))
                                              (cancel-timer timer))))
            roost-reader--timer timer)))
  (roost-reader--header))

(defun roost-reader-reload ()
  "Read the log again from the start."
  (interactive)
  (let ((inhibit-read-only t))
    ;; Erasing the text leaves its web views alive.
    (when (fboundp 'get-buffer-xwidgets)
      (mapc #'kill-xwidget (get-buffer-xwidgets (current-buffer))))
    (erase-buffer)
    (setq roost-reader--offset 0 roost-reader--tools nil roost-reader--turns 0)
    (roost-reader--append)
    (goto-char (point-min))))

;;;###autoload
(defun roost-reader-open-file (file)
  "Read the Claude Code session log FILE, typeset, and follow it."
  (interactive (list (read-file-name "Session log: " (expand-file-name "~/.claude/projects/") nil t)))
  (let ((buffer (get-buffer-create (format "*session %s*" (file-name-base file)))))
    (with-current-buffer buffer
      (roost-reader-mode)
      (setq roost-reader--file file)
      (pop-to-buffer-same-window buffer)
      (roost-reader--fit-column)
      (roost-reader-reload)
      (roost-reader-follow))
    buffer))

(defun roost-reader--project-directory (host worktree)
  "Where Claude Code keeps the logs of sessions in WORKTREE on HOST."
  (roost--host-directory host (concat "~/.claude/projects/"
                                      (replace-regexp-in-string "[^a-zA-Z0-9]" "-" worktree))))

;;;###autoload
(defun roost-reader (&optional task)
  "Read TASK's latest agent session, typeset."
  (interactive)
  (require 'roost)
  (setq task (roost--choose task))
  (let* ((directory (roost-reader--project-directory (roost--field task 'host)
                                                     (roost--field task 'worktree)))
         (logs (and (file-directory-p directory)
                    (directory-files directory t "\\.jsonl\\'"))))
    (unless logs (user-error "No session log for %s yet" (roost--field task 'name)))
    (roost-reader-open-file (car (sort logs #'file-newer-than-file-p)))))

(provide 'roost-reader)
;;; roost-reader.el ends here
