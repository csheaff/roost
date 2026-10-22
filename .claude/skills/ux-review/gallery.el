;;; gallery.el --- Draw Roost's views for every gallery state, as text  -*- lexical-binding: t -*-

;; For a UX review: the states of test/roost-sweep.el's gallery, each
;; drawn as the task panel docked beside its terminal (44 columns), the
;; panel in the main window (100), and the sidebar, dashboard and a draft
;; for them all.  From the repository's top:
;;
;;   GALLERY_OUT=/tmp/gallery emacs -Q --batch -L . -L test \
;;     -l test/roost-test.el -l .claude/skills/ux-review/gallery.el
;;
;; Text loses faces and line prefixes; look at make qa's screenshots for
;; those.

;;; Code:

(require 'roost-sweep)

(defvar gallery-out (or (getenv "GALLERY_OUT") (make-temp-file "roost-gallery" t)))

(defun gallery--draw (view state width layout)
  "VIEW drawn for gallery STATE at WIDTH in LAYOUT, as text."
  (save-window-excursion
    (with-current-buffer (roost-sweep--draw view state width layout)
      (prog1 (buffer-substring-no-properties (point-min) (point-max))
        (kill-buffer)))))

(defun gallery--write (file text)
  "Write TEXT to FILE in `gallery-out'."
  (with-temp-file (expand-file-name file gallery-out) (insert text)))

(defun gallery--panels (beside width)
  "Every state's task panel at WIDTH, BESIDE the terminal or not."
  (mapconcat (lambda (state)
               (concat "\n================ " state " ================\n"
                       (cl-letf (((symbol-function 'roost--panel-beside-terminal-p)
                                  (lambda (_) beside)))
                         (gallery--draw 'panel state width 'selected))))
             (mapcar #'car roost-sweep--gallery) ""))

(roost-test--isolated
 (let ((native-comp-enable-subr-trampolines nil))
   (make-directory gallery-out t)
   (roost-sweep--populate)
   (gallery--write "panel-44-beside.txt" (gallery--panels t 44))
   (gallery--write "panel-100-main.txt" (gallery--panels nil 100))
   ;; In a window as wide as the sidebar's, as it shows.
   (gallery--write "sidebar.txt"
                   (save-window-excursion
                     (delete-other-windows)
                     (split-window-right (1+ roost-sidebar-width))
                     (with-current-buffer (get-buffer-create "*gallery sidebar*")
                       (roost-sidebar-list-mode)
                       (set-window-buffer (selected-window) (current-buffer))
                       (roost--render-sidebar)
                       (buffer-substring-no-properties (point-min) (point-max)))))
   (gallery--write "dashboard.txt" (gallery--draw 'dashboard (caar roost-sweep--gallery) nil 'selected))
   (gallery--write "draft.txt" (gallery--draw 'draft "ready, reviewing" nil 'selected))
   (gallery--write
    "next-steps.txt"
    (mapconcat (lambda (state)
                 (let ((task (gethash (roost-sweep--key state) roost--tasks)))
                   (format "%-28s %-12s waits: %-3s next: %s\n" state (roost--display-status task)
                           (if (roost--waiting-p task) "yes" "no")
                           (substring-no-properties (or (roost--next-step task) "")))))
               (mapcar #'car roost-sweep--gallery) ""))
   (message "Wrote the gallery to %s" gallery-out)))

;;; gallery.el ends here
