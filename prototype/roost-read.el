;;; roost-read.el --- Read a Claude conversation, typeset, in a buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; A throwaway prototype, not part of Roost.  `roost-read' shows a Claude
;; Code conversation as an ordinary Emacs buffer: each turn is your prompt
;; and the agent's last reply, typeset, with the steps between folded and
;; the turn's screenshots as thumbnails.  Where the agent showed something
;; interactive, a WebKit view sits in the text at that point.
;;
;; On macOS an embedded web view is not kept inside its window: one cut by
;; the window's bottom edge draws over what is below.  So a widget is live
;; only while all of it is in view, in the one window showing the buffer;
;; otherwise a still placeholder of the same size stands in for it.
;;
;; The Markdown renderer and faces come from the earlier reader prototype
;; (branch reader-prototype).  It needs python3; widgets need an Emacs
;; built with xwidgets and a graphical frame, and show as placeholders
;; without them.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'xml)
(require 'xwidget nil t)

(declare-function xwidget-webkit-goto-uri "xwidget" (xwidget uri))
(declare-function xwidget-webkit-execute-script "xwidget" (xwidget script &optional callback))
(declare-function xwidget-resize "xwidget.c" (xwidget new-width new-height))
(declare-function xwidget-put "xwidget.c" (xwidget propname value))
(declare-function xwidget-live-p "xwidget.c" (object))
(declare-function xwidget-buffer "xwidget.c" (xwidget))
(declare-function roost--choose "roost" (&optional task))
(declare-function roost--field "roost" (task field))
(declare-function roost--send-draft "roost" (task &optional initial))
(declare-function roost--as-listed "roost" (task))
(defvar roost-task-info-mode-map)
(defvar roost-dashboard-mode-map)
(declare-function make-xwidget "xwidget.c" (type title width height &optional args buffer related))
(declare-function kill-xwidget "xwidget.c" (xwidget))
(declare-function get-buffer-xwidgets "xwidget.c" (buffer))
(declare-function set-xwidget-query-on-exit-flag "xwidget.c" (xwidget flag))
(declare-function xwidget-webkit-browse-url "xwidget" (url &optional new-session))

(defgroup roost-read nil
  "Read a coding agent's conversation, typeset."
  :group 'tools)

(defcustom roost-read-serif "Charter"
  "Family for prose."
  :type 'string)

(defcustom roost-read-mono "Menlo"
  "Family for code and tool calls."
  :type 'string)

(defcustom roost-read-measure 70
  "Width of the reading column, in characters of prose."
  :type 'natnum)

(defface roost-read-prose `((t :family ,roost-read-serif :height 165)) "Prose.")
(defface roost-read-h1 `((t :family ,roost-read-serif :weight bold :height 1.45)) "Level 1 heading.")
(defface roost-read-h2 `((t :family ,roost-read-serif :weight bold :height 1.25)) "Level 2 heading.")
(defface roost-read-h3 `((t :family ,roost-read-serif :weight bold :height 1.1)) "Level 3 heading.")
(defface roost-read-bold '((t :weight bold)) "Strong emphasis.")
(defface roost-read-italic '((t :slant italic)) "Emphasis.")
(defface roost-read-inline-code
  `((((background dark)) :family ,roost-read-mono :height 0.85 :background "#2b2e36")
    (t :family ,roost-read-mono :height 0.85 :background "#eceae4"))
  "Inline code.")
(defface roost-read-code
  `((((background dark)) :family ,roost-read-mono :height 0.85 :background "#22252c" :extend t)
    (t :family ,roost-read-mono :height 0.85 :background "#f3f1ec" :extend t))
  "Code blocks.")
(defface roost-read-bullet '((t :inherit shadow)) "List markers.")
(defface roost-read-quote '((t :inherit shadow :slant italic)) "Block quotes.")
(defface roost-read-rule '((t :inherit shadow :strike-through t)) "Horizontal rules.")
(defface roost-read-user
  '((((background dark)) :background "#1d2a24" :extend t)
    (t :background "#eaf3ec" :extend t))
  "Your prompts.")
(defface roost-read-tool
  `((t :inherit shadow :family ,roost-read-mono :height 0.8))
  "A tool call's one-line summary.")
(defface roost-read-tool-failed
  `((t :inherit error :family ,roost-read-mono :height 0.8))
  "A tool call that failed.")
(defface roost-read-detail
  `((((background dark)) :family ,roost-read-mono :height 0.78 :foreground "#a9adb6" :background "#202228" :extend t)
    (t :family ,roost-read-mono :height 0.78 :foreground "#55585e" :background "#f6f5f1" :extend t))
  "A tool call's details, unfolded.")
(defface roost-read-diagram-title
  `((t :inherit shadow :family ,roost-read-serif :slant italic :height 0.9))
  "A diagram's title.")
(defface roost-read-note '((t :inherit shadow :slant italic)) "Notes about the session.")

;;;; Markdown

(defun roost-read--insert-inline (text)
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
                   (roost-read--insert-inline inner)
                   (add-face-text-property from (point) 'roost-read-bold))
                 (set-match-data (list whole-start end))))
              ((match-beginning 2)
               (insert (substring text start whole-start)
                       (propertize (match-string 2 text) 'face 'roost-read-inline-code)))
              ((match-beginning 3)
               (insert (substring text start whole-start))
               (let ((url (match-string 4 text)))
                 (insert-text-button (match-string 3 text) 'action (lambda (_) (browse-url url))
                                     'follow-link t 'help-echo url)))
              (t
               (let ((group (if (match-beginning 5) 5 6)))
                 ;; Up to the opening delimiter, which is dropped.
                 (insert (substring text start (1- (match-beginning group))))
                 (insert (propertize (match-string group text) 'face 'roost-read-italic))
                 (when (and (= group 6) (< (match-beginning group) (match-end 0))
                            (> (match-end 0) (1+ (match-end group))))
                   (insert (substring text (1+ (match-end group)) (match-end 0)))))))
        (setq start (match-end 0))))
    (insert (substring text start))))

(defun roost-read--paragraph-break ()
  "Leave one blank line before what is inserted next, unless one is there."
  (unless (or (bobp) (and (eq (char-before) ?\n) (eq (char-before (1- (point))) ?\n)))
    (insert (if (eq (char-before) ?\n) "\n" "\n\n"))))

(defconst roost-read--modes
  '(("emacs-lisp" . emacs-lisp-mode) ("elisp" . emacs-lisp-mode) ("lisp" . lisp-mode)
    ("python" . python-mode) ("py" . python-mode) ("sh" . sh-mode) ("bash" . sh-mode)
    ("shell" . sh-mode) ("console" . sh-mode) ("zsh" . sh-mode) ("js" . js-mode)
    ("javascript" . js-mode) ("ts" . typescript-ts-mode) ("json" . js-json-mode)
    ("c" . c-mode) ("diff" . diff-mode) ("ruby" . ruby-mode) ("go" . go-ts-mode)
    ("rust" . rust-ts-mode) ("css" . css-mode) ("html" . mhtml-mode) ("toml" . conf-toml-mode)
    ("yaml" . yaml-ts-mode) ("sql" . sql-mode) ("org" . org-mode) ("markdown" . text-mode))
  "Major modes that highlight code blocks, by language name.")

(defun roost-read--fontify (code language)
  "CODE highlighted as LANGUAGE, if Emacs has a mode for it."
  (let ((mode (cdr (assoc (downcase (or language "")) roost-read--modes))))
    (if (not (and mode (fboundp mode)))
        code
      (with-temp-buffer
        (insert code)
        ;; Without your mode hooks: no servers start for a code block.
        (delay-mode-hooks (ignore-errors (funcall mode)))
        (ignore-errors (font-lock-ensure))
        (buffer-string)))))

(defun roost-read--insert-code (code language)
  "Insert CODE, a block in LANGUAGE."
  (let ((start (point)))
    (insert (roost-read--fontify (string-trim-right code) language) "\n")
    (add-face-text-property start (point) 'roost-read-code t)
    (add-text-properties start (point) '(line-prefix "  " wrap-prefix "  "))))

(defface roost-read-table-rule
  '((((background dark)) :underline (:color "#3b3f48" :position 8))
    (t :underline (:color "#d9d5ca" :position 8)))
  "The line under a table row.")

(defun roost-read--table-cells (line)
  "The cells of the Markdown table row LINE."
  (mapcar #'string-trim
          (split-string (replace-regexp-in-string "\\`\\s-*|\\||\\s-*\\'" "" line) "|")))

(defun roost-read--rendered-inline (text)
  "TEXT with its inline Markdown rendered, as a string."
  (with-temp-buffer (roost-read--insert-inline text) (buffer-string)))

(defun roost-read--insert-table (lines)
  "Insert the Markdown table LINES with its columns aligned.
A table too wide for the column is shown as written."
  (let* ((rows (mapcar (lambda (line) (mapcar #'roost-read--rendered-inline
                                              (roost-read--table-cells line)))
                       (seq-remove (lambda (line) (string-match-p "\\`[ \t|:-]+\\'" line)) lines)))
         (width (lambda (cell bold)
                  (let ((cell (copy-sequence cell)))
                    (when bold (add-face-text-property 0 (length cell) 'roost-read-bold t cell))
                    ;; Measured in the prose face, as the reader shows it.
                    (add-face-text-property 0 (length cell) 'roost-read-prose t cell)
                    (string-pixel-width cell))))
         (count (apply #'max (mapcar #'length rows)))
         (gap (* 2 (string-pixel-width (propertize "n" 'face 'roost-read-prose))))
         (widths (mapcar (lambda (i)
                           (apply #'max (seq-map-indexed (lambda (row n)
                                                           (funcall width (or (nth i row) "") (= n 0)))
                                                         rows)))
                         (number-sequence 0 (1- count))))
         (stops (let ((x 0)) (mapcar (lambda (w) (setq x (+ x w gap))) widths))))
    (if (> (car (last stops)) (roost-read--column-pixels))
        (roost-read--insert-stacked-table rows)
      (seq-do-indexed
       (lambda (row n)
         (let ((start (point)))
           (seq-do-indexed (lambda (cell i)
                             (insert (if (= n 0) (propertize cell 'face 'roost-read-bold) cell)
                                     (propertize " " 'display `(space :align-to (,(nth i stops))))))
                           row)
           (when (< n (1- (length rows)))
             (add-face-text-property start (point) 'roost-read-table-rule t))
           (insert "\n")))
       rows))))

(defun roost-read--insert-stacked-table (rows)
  "Insert the table ROWS, too wide for the column, one row after another.
Each row's first cell heads it, and its other cells follow, named by
their column."
  (let ((header (car rows)))
    (dolist (row (cdr rows))
      (insert (propertize (or (car row) "") 'face 'roost-read-bold) "\n")
      (seq-do-indexed (lambda (cell i)
                        (let ((start (point)))
                          (insert "  " (propertize (or (nth (1+ i) header) "") 'face 'roost-read-note)
                                  " — " cell "\n")
                          (put-text-property start (point) 'wrap-prefix "    ")))
                      (cdr row)))))

(defun roost-read--insert-markdown (text)
  "Insert TEXT, Markdown, rendered."
  (let ((lines (split-string text "\n")) code language table)
    (cl-flet ((flush-table ()
                (when table
                  (roost-read--insert-table (nreverse table))
                  (setq table nil))))
      (dolist (line lines)
        (cond
         ((string-match "^ *```\\(.*\\)$" line)
          (if code
              (progn (roost-read--insert-code (string-join (nreverse (cdr code)) "\n") language)
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
                                  (pcase level (1 'roost-read-h1) (2 'roost-read-h2) (_ 'roost-read-h3)))
                      "\n")))
           ((string-match "^\\( *\\)\\([-*+]\\|[0-9]+[.)]\\) +\\(.*\\)$" line)
            (let* ((indent (match-string 1 line))
                   (marker (match-string 2 line))
                   (bullet (if (string-match-p "[0-9]" marker) (concat marker " ") "•  "))
                   (prefix (concat "  " indent (make-string (length bullet) ?\s)))
                   (start (point)))
              (insert "  " indent (propertize bullet 'face 'roost-read-bullet))
              (roost-read--insert-inline (match-string 3 line))
              (insert "\n")
              (put-text-property start (point) 'wrap-prefix prefix)))
           ((string-match "^> ?\\(.*\\)$" line)
            (let ((start (point)))
              (roost-read--insert-inline (match-string 1 line))
              (insert "\n")
              (add-face-text-property start (point) 'roost-read-quote)
              (add-text-properties start (point) '(line-prefix "│ " wrap-prefix "│ "))))
           ((string-match "^ *\\(---+\\|\\*\\*\\*+\\) *$" line)
            (insert (propertize (make-string 30 ?\s) 'face 'roost-read-rule) "\n"))
           (t (roost-read--insert-inline line) (insert "\n"))))))
      (when code
        (roost-read--insert-code (string-join (nreverse (cdr code)) "\n") language))
      (flush-table))))

;;;; The conversation

(defconst roost-read--script
  (expand-file-name "transcript_html.py"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The program that reads a session log into turns.")

(defvar roost-read-send-function
  (lambda (kind text) (message "Widget %s: %s" kind text))
  "What to do when a widget asks for something.
Called with KIND, \"prompt\" or \"link\", and its TEXT.  The prototype
only says what was asked; Roost would send a prompt to the task.")

(defvar roost-read-asked nil
  "What widgets have asked for, newest first, as (KIND . TEXT).")

(defvar-local roost-read--log nil "The session log shown.")
(defvar-local roost-read--folder nil "Where this buffer's images and widget pages are.")
(defvar-local roost-read--widgets nil "This buffer's widgets, each a plist in a cons cell.")
(defvar-local roost-read--timer nil "The timer that keeps this buffer's widgets in step.")

(defun roost-read--column-pixels ()
  "Width of the reading column in pixels."
  (let ((window (get-buffer-window nil t)))
    (min (if window (window-body-width window t) 900)
         (* roost-read-measure (string-pixel-width (propertize "n" 'face 'roost-read-prose))))))

(defun roost-read--fit-column (&optional window)
  "Center the reading column in the windows showing WINDOW's buffer."
  (dolist (window (get-buffer-window-list (if (windowp window) (window-buffer window) (current-buffer))
                                          nil t))
    (let* ((text (with-current-buffer (window-buffer window) (roost-read--column-pixels)))
           (spare (max 0 (- (window-pixel-width window) text 40)))
           (columns (/ spare 2 (frame-char-width (window-frame window)))))
      (set-window-margins window columns columns))))

(defun roost-read--turns (log folder)
  "Read LOG into FOLDER and return its turns."
  (with-temp-buffer
    (unless (eq 0 (call-process "python3" nil t nil "-I" roost-read--script "--json" log folder))
      (error "Could not read %s: %s" log (string-trim (buffer-string)))))
  (with-temp-buffer
    (insert-file-contents (expand-file-name "turns.json" folder))
    (json-parse-buffer :object-type 'alist :array-type 'list :null-object nil)))

(defun roost-read--toggle-fold (button)
  "Show or hide the steps under BUTTON."
  (let* ((overlay (button-get button 'roost-read-steps))
         (hidden (overlay-get overlay 'invisible))
         (inhibit-read-only t))
    (overlay-put overlay 'invisible (not hidden))
    (save-excursion
      (goto-char (button-start button))
      (let ((properties (text-properties-at (point))))
        (delete-char 1)
        (insert (apply #'propertize (if hidden "▾" "▸") properties))))))

(defun roost-read--insert-steps (steps)
  "Insert STEPS, what the agent did before its reply, folded to one line."
  (let* ((tools (seq-count (lambda (step) (equal (car step) "tool")) steps))
         (notes (- (length steps) tools))
         (label (string-join
                 (delq nil (list (and (> tools 0) (format "%d tool call%s" tools (if (= tools 1) "" "s")))
                                 (and (> notes 0) (format "%d note%s" notes (if (= notes 1) "" "s")))))
                 ", "))
         (start (point))
         from)
    (insert "▸ " label "\n")
    (setq from (point))
    (dolist (step steps)
      (if (equal (car step) "tool")
          (insert (propertize (format "  %s %s\n" (nth 1 step) (or (nth 2 step) ""))
                              'face 'roost-read-tool))
        (let ((at (point)))
          (roost-read--insert-markdown (nth 1 step))
          (add-face-text-property at (point) 'roost-read-note t)
          (add-text-properties at (point) '(line-prefix "  │ " wrap-prefix "  │ ")))))
    (let ((overlay (make-overlay from (point))))
      (overlay-put overlay 'invisible t)
      (make-text-button start (1- from) 'face 'roost-read-tool 'follow-link t
                        'roost-read-steps overlay 'action #'roost-read--toggle-fold))))

(defun roost-read--toggle-image (button)
  "Show the screenshot under BUTTON large, or small again."
  (let* ((file (button-get button 'roost-read-image))
         (large (not (button-get button 'roost-read-large)))
         (inhibit-read-only t))
    (button-put button 'roost-read-large large)
    (put-text-property (button-start button) (button-end button) 'display
                       (if large
                           (create-image file nil nil :max-width (roost-read--column-pixels))
                         (create-image file nil nil :max-height 56 :max-width 110)))))

(defun roost-read--insert-images (files)
  "Insert the screenshots in FILES as thumbnails that grow when clicked."
  (dolist (file files)
    (when (file-readable-p file)
      (insert-text-button "*" 'display (create-image file nil nil :max-height 56 :max-width 110)
                          'face 'default 'follow-link t 'help-echo "Click to enlarge"
                          'roost-read-image file 'action #'roost-read--toggle-image)
      (insert " ")))
  (when files (insert "\n\n")))

;;;; Widgets

(defun roost-read--placeholder (widget)
  "A still image the size of WIDGET, standing in for it."
  (let* ((width (plist-get widget :width))
         (height (plist-get widget :height))
         (dark (eq (frame-parameter nil 'background-mode) 'dark))
         (title (replace-regexp-in-string "[_-]" " " (or (plist-get widget :title) "")))
         (text (xml-escape-string
                (concat "◆ " (if (string-empty-p title) "Interactive" title)
                        (if (featurep 'xwidget-internal)
                            " — live when all of it is in view; click to open it alone"
                          " — needs an Emacs with xwidgets")))))
    (create-image
     (format (concat "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d'>"
                     "<rect x='1' y='1' width='%d' height='%d' rx='12' fill='%s' stroke='%s'/>"
                     "<text x='%d' y='%d' text-anchor='middle' font-family='-apple-system,Helvetica' "
                     "font-size='14' fill='%s'>%s</text></svg>")
             width height (- width 2) (- height 2)
             (if dark "#26242b" "#f4f1ea") (if dark "#3a3840" "#dcd7cc")
             (/ width 2) (/ height 2) (if dark "#8f897f" "#7a746c") text)
     'svg t :ascent 'center)))

(defun roost-read--widget-at (position)
  "The widget whose placeholder is at POSITION, or nil."
  (get-text-property position 'roost-read-widget))

(defun roost-read--open-widget (button)
  "Open the widget under BUTTON in a WebKit window of its own."
  (let ((widget (car (button-get button 'roost-read-widget))))
    (if (featurep 'xwidget-internal)
        (xwidget-webkit-browse-url (concat "file://" (plist-get widget :file)) t)
      (browse-url (concat "file://" (plist-get widget :file))))))

(defun roost-read--insert-widget (entry)
  "Insert the widget ENTRY, an alist of its title and page file."
  (let* ((width (roost-read--column-pixels))
         (cell (list (list :file (alist-get 'file entry) :title (alist-get 'title entry)
                           :width width :height 200 :live nil :marker (point-marker)))))
    (when (and (featurep 'xwidget-internal) (display-graphic-p))
      (let ((xwidget (make-xwidget 'webkit "roost widget" width 200 nil (current-buffer))))
        (set-xwidget-query-on-exit-flag xwidget nil)
        (xwidget-put xwidget 'callback #'roost-read--event)
        (xwidget-put xwidget 'roost-read-cell cell)
        (xwidget-webkit-goto-uri xwidget (concat "file://" (alist-get 'file entry)))
        (setcar cell (plist-put (car cell) :xwidget xwidget))))
    (push cell roost-read--widgets)
    (insert-text-button "*" 'display (roost-read--placeholder (car cell)) 'face 'default
                        'follow-link t 'roost-read-widget cell 'action #'roost-read--open-widget)
    (insert "\n\n")))

(defconst roost-read--ask
  (concat "JSON.stringify({height: Math.ceil(document.body.getBoundingClientRect().height),"
          " out: (window.roostOutbox || []).splice(0)})")
  "The script that asks a widget's page its height and what was clicked.")

(defun roost-read--event (xwidget type)
  "Handle XWIDGET's event of TYPE: fit it to its page, pass on what was clicked.
Emacs delivers a script's result as an event to the view's callback, so
no closure waits on WebKit, which Emacs would be free to collect."
  (pcase type
    ('load-changed
     (when (equal (nth 3 last-input-event) "load-finished")
       (let ((background (face-background 'default nil t)))
         (xwidget-webkit-execute-script
          xwidget (format (concat "document.documentElement.style.background = %S;"
                                  "document.documentElement.dataset.mode = %S")
                          background
                          (if (eq (frame-parameter nil 'background-mode) 'dark) "dark" "light"))))
       (xwidget-webkit-execute-script xwidget roost-read--ask #'ignore)))
    ('javascript-callback
     (let* ((reply (nth 4 last-input-event))
            (data (and (stringp reply)
                       (ignore-errors (json-parse-string reply :object-type 'alist
                                                         :array-type 'list :null-object nil))))
            (cell (xwidget-get xwidget 'roost-read-cell))
            (height (alist-get 'height data)))
       (dolist (item (alist-get 'out data))
         (push (cons (alist-get 'kind item) (alist-get 'text item)) roost-read-asked)
         ;; In the conversation's buffer, which may say where a prompt goes.
         (with-current-buffer (xwidget-buffer xwidget)
           (funcall roost-read-send-function (alist-get 'kind item) (alist-get 'text item))))
       (when (and cell (numberp height) (> height 0)
                  (/= (round height) (plist-get (car cell) :height)))
         (setcar cell (plist-put (car cell) :height (min 1400 (max 40 (round height)))))
         (roost-read--resize cell))))))

(defun roost-read--resize (cell)
  "Give the widget in CELL its page's size, in its view and its placeholder."
  (let* ((widget (car cell))
         (marker (plist-get widget :marker)))
    (when (buffer-live-p (marker-buffer marker))
      (with-current-buffer (marker-buffer marker)
        (when (xwidget-live-p (plist-get widget :xwidget))
          (xwidget-resize (plist-get widget :xwidget) (plist-get widget :width)
                          (plist-get widget :height)))
        (setcar cell (plist-put widget :live 'stale))
        (roost-read--arrange)))))

(defun roost-read--arrange (&rest _)
  "Show each widget live if all of it is in view, else its placeholder.
On macOS a web view cut by its window's edge draws outside the window,
and one buffer's view cannot show in two windows."
  (when (derived-mode-p 'roost-read-mode)
    (let* ((windows (get-buffer-window-list nil nil t))
           (window (and (null (cdr windows)) (car windows)))
           (inhibit-read-only t))
      (dolist (cell roost-read--widgets)
        (let* ((widget (car cell))
               (position (marker-position (plist-get widget :marker)))
               (xwidget (plist-get widget :xwidget))
               (seen (and window xwidget (xwidget-live-p xwidget)
                          (pos-visible-in-window-p position window t)))
               (whole (and seen (null (cddr seen))))
               (want (if whole 'live 'still)))
          (unless (eq want (plist-get widget :live))
            (setcar cell (plist-put widget :live want))
            (with-silent-modifications
              (put-text-property position (1+ position) 'display
                                 (if whole
                                     (list 'xwidget :xwidget xwidget)
                                   (roost-read--placeholder widget))))))))))

(defun roost-read--tick (buffer)
  "Keep BUFFER's widgets in step: which are live, their sizes, their clicks."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (get-buffer-window buffer t)
        (roost-read--arrange)
        (dolist (cell roost-read--widgets)
          (let ((xwidget (plist-get (car cell) :xwidget)))
            (when (and xwidget (xwidget-live-p xwidget) (eq (plist-get (car cell) :live) 'live))
              (xwidget-webkit-execute-script xwidget roost-read--ask #'ignore))))))))

;;;; The buffer

(defun roost-read--insert-turn (turn)
  "Insert TURN: your prompt, what the agent did, folded, and its reply."
  (let ((start (point)))
    (if (alist-get 'event turn)
        (insert (propertize (format "Sent by the app: %s\n"
                                    (replace-regexp-in-string "-" " " (alist-get 'event turn)))
                            'face 'roost-read-note))
      (roost-read--insert-markdown (alist-get 'prompt turn))
      (add-face-text-property start (point) 'roost-read-user t)
      (add-text-properties start (point) '(line-prefix "  " wrap-prefix "  ")))
    (put-text-property start (min (point-max) (1+ start)) 'roost-read-prompt t))
  (roost-read--insert-images (alist-get 'attached turn))
  (insert "\n")
  (when (alist-get 'steps turn)
    (roost-read--insert-steps (alist-get 'steps turn))
    (insert "\n"))
  (roost-read--insert-images (alist-get 'images turn))
  (mapc #'roost-read--insert-widget (alist-get 'widgets turn))
  (if (alist-get 'reply turn)
      (roost-read--insert-markdown (alist-get 'reply turn))
    (insert (propertize "No reply yet.\n" 'face 'roost-read-note)))
  (insert "\n\n"))

(defun roost-read-next-prompt ()
  "Move to your next prompt."
  (interactive)
  (forward-char 1)
  (if-let* ((next (text-property-search-forward 'roost-read-prompt t t)))
      (progn (goto-char (prop-match-beginning next)) (recenter 1))
    (forward-char -1)))

(defun roost-read-previous-prompt ()
  "Move to your previous prompt."
  (interactive)
  (when-let* ((previous (text-property-search-backward 'roost-read-prompt t t)))
    (goto-char (prop-match-beginning previous))
    (recenter 1)))

(defun roost-read--stop ()
  "Stop keeping this buffer's widgets in step, and close them."
  (when (timerp roost-read--timer) (cancel-timer roost-read--timer))
  (setq roost-read--timer nil)
  (when (fboundp 'get-buffer-xwidgets)
    (mapc #'kill-xwidget (get-buffer-xwidgets (current-buffer)))))

(defun roost-read-again ()
  "Read the session log again and show the newest turn."
  (interactive)
  (let ((inhibit-read-only t))
    (when (fboundp 'get-buffer-xwidgets)
      (mapc #'kill-xwidget (get-buffer-xwidgets (current-buffer))))
    (mapc #'delete-overlay (overlays-in (point-min) (point-max)))
    (erase-buffer)
    (setq roost-read--widgets nil)
    (mapc #'roost-read--insert-turn (roost-read--turns roost-read--log roost-read--folder))
    (goto-char (point-max))
    (roost-read-previous-prompt)
    (setq header-line-format
          (format "  %s · n/p prompts · TAB steps · g again · q back"
                  (file-name-base roost-read--log)))))

(defvar-keymap roost-read-mode-map
  :parent special-mode-map
  "TAB" #'forward-button
  "<backtab>" #'backward-button
  "n" #'roost-read-next-prompt
  "p" #'roost-read-previous-prompt
  "g" #'roost-read-again)

(define-derived-mode roost-read-mode special-mode "Read"
  "A coding agent's conversation, typeset.
\\{roost-read-mode-map}"
  (buffer-face-set 'roost-read-prose)
  (setq-local line-spacing 0.3
              truncate-lines nil
              word-wrap t
              cursor-type 'bar
              kill-buffer-query-functions
              (remq 'xwidget-kill-buffer-query-function
                    (default-value 'kill-buffer-query-functions)))
  (visual-line-mode 1)
  (add-hook 'window-size-change-functions #'roost-read--fit-column nil t)
  (add-hook 'kill-buffer-hook #'roost-read--stop nil t))

(defun roost-read--newest (directory)
  "The newest Claude session log of DIRECTORY, or nil."
  (let ((folder (expand-file-name
                 (replace-regexp-in-string "[^A-Za-z0-9]" "-"
                                           (directory-file-name (file-truename directory)))
                 "~/.claude/projects/")))
    (when (file-directory-p folder)
      (car (sort (directory-files folder t "\\.jsonl\\'") #'file-newer-than-file-p)))))

;;;###autoload
(defun roost-read (log)
  "Read the Claude conversation in session LOG, typeset, in a buffer.
LOG is the newest conversation of the current directory, or with a
prefix argument, or when there is none, one you pick."
  (interactive
   (list (or (and (not current-prefix-arg) (roost-read--newest default-directory))
             (read-file-name "Session log: " "~/.claude/projects/" nil t))))
  (let ((buffer (get-buffer-create (format "*read %s*" (file-name-base log)))))
    (pop-to-buffer-same-window buffer)
    (roost-read-mode)
    (setq roost-read--log (expand-file-name log)
          roost-read--folder (expand-file-name (concat "roost-read-" (file-name-base log))
                                               temporary-file-directory))
    (roost-read--fit-column)
    (roost-read-again)
    (setq roost-read--timer (run-at-time 0.5 0.5 #'roost-read--tick buffer))
    buffer))

;;;; In Roost

;;;###autoload
(defun roost-read-task (&optional task)
  "Read the conversation of TASK, a Roost task of Claude's on this machine.
What a widget in it asks to send becomes a draft to the task."
  (interactive)
  (require 'roost)
  (setq task (roost--choose task))
  (let* ((worktree (roost--field task 'worktree))
         (log (and (stringp worktree) (not (file-remote-p worktree))
                   (file-directory-p worktree)
                   (roost-read--newest worktree))))
    (unless log
      (user-error "No Claude conversation on this machine for %s" (roost--field task 'name)))
    (with-current-buffer (roost-read log)
      (setq-local roost-read-send-function
                  (lambda (kind text)
                    (if (equal kind "prompt")
                        (roost--send-draft (roost--as-listed task) text)
                      (message "Widget %s: %s" kind text)))))))

(with-eval-after-load 'roost
  (keymap-set roost-task-info-mode-map "V" #'roost-read-task)
  (keymap-set roost-dashboard-mode-map "V" #'roost-read-task))

(provide 'roost-read)
;;; roost-read.el ends here
