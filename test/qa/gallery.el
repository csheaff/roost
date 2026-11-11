;;; gallery.el --- Pictures of Roost's views in every task state -*- lexical-binding: t; -*-

;; `make gallery' draws the task panel and the dashboard for the sweep's
;; gallery of task states (test/roost-sweep.el), a few to a sheet, and
;; captures each sheet as a PNG: how Roost looks, without an
;; agent, tmux or a host, in seconds.  It needs a display and
;; ImageMagick's `import'; on Linux, Xvfb will do:
;;
;;   Xvfb :99 -screen 0 1760x1000x24 & DISPLAY=:99 make gallery
;;
;; GALLERY_THEME names a theme to load first, as modus-vivendi, and
;; GALLERY_OUT the folder the sheets go in.

(require 'roost)
(require 'roost-sweep)

(defvar roost-gallery--panel-states
  '(("running" "permission" "ready, reviewing" "after a later prompt")
    ("failed turn" "crashed" "worktree gone" "merge conflicts")
    ("on another branch" "detached, stopped" "conflicts with main" "behind")
    ("pull request open" "pull request to merge" "pull request, ci failed" "pull request with comments")
    ("many files" "changed since you looked" "large change" "with notes")
    ("offers a task" "started from another task" "conversation" "pull request merged"))
  "The gallery states the panel is drawn for, a sheet to each list.")

(defun roost-gallery--copy (view state width)
  "The text of VIEW drawn for gallery STATE at WIDTH, with its faces."
  (let (text)
    ;; A state that asks, or reaches outside, as the sweep's world has it,
    ;; says so in its column rather than stop the gallery.
    (condition-case err
        (roost-sweep--world
          (save-window-excursion
            (let ((buffer (roost-sweep--draw view state width)))
              (unwind-protect
                  (setq text (with-current-buffer buffer (buffer-string)))
                (kill-buffer buffer)))))
      ((quit error) (setq text (format "Could not draw this:\n%S" err))))
    text))

(defun roost-gallery--show (columns &optional list)
  "Show COLUMNS, each (TITLE WIDTH . TEXT), side by side in the frame.
With LIST, as a list of tasks is: each line cut at its window's edge,
in a window just as wide as it was drawn for."
  (delete-other-windows)
  (let ((window (selected-window)) (n 0))
    (dolist (column columns)
      (pcase-let ((`(,title ,width . ,text) column))
        (let ((buffer (get-buffer-create (format "*gallery %d*" (cl-incf n)))))
          (with-current-buffer buffer
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert text))
            (goto-char (point-min))
            ;; A draft's faces are font-lock's.
            (font-lock-mode 1)
            (setq mode-line-format nil
                  cursor-type nil
                  truncate-lines list
                  truncate-partial-width-windows nil
                  line-spacing (and list roost--line-spacing)
                  ;; As the panel has it: no arrows where a line wraps.
                  fringe-indicator-alist '((continuation nil nil) (truncation nil nil))
                  word-wrap (not list)
                  header-line-format (propertize (concat " " title) 'face 'shadow)))
          (set-window-buffer window buffer)
          (set-window-fringes window (if list 0 8) (if list 0 8))
          (when (cdr (memq column columns))
            (setq window (split-window window (+ width (if list 2 3)) t))))))))

(defun roost-gallery--capture (file)
  "Capture the display as FILE."
  (redisplay t)
  (sit-for 0.3)
  (call-process "import" nil nil nil "-window" "root" file)
  ;; The tests note each program started, to hold Roost to its list:
  ;; this one is the gallery's.
  (setq roost-test--forbidden nil))

(defun roost-gallery ()
  "Draw every sheet and capture it, then exit."
  (let ((out (file-name-as-directory (or (getenv "GALLERY_OUT") (make-temp-file "roost-gallery" t))))
        (theme (getenv "GALLERY_THEME"))
        (n 0))
    (make-directory out t)
    (when (and theme (not (string-empty-p theme)))
      (load-theme (intern theme) t))
    ;; As a plain Emacs has them off in most setups, and they aren't Roost's.
    (menu-bar-mode -1)
    (tool-bar-mode -1)
    (scroll-bar-mode -1)
    (set-frame-size nil 190 52)
    (dolist (states roost-gallery--panel-states)
      (roost-gallery--show
       (mapcar (lambda (state) (cons state (cons 44 (roost-gallery--copy 'panel state 44)))) states))
      (roost-gallery--capture (format "%spanel-%d.png" out (cl-incf n))))
    ;; The views that are neither a task's panel nor a list of tasks.
    (roost-gallery--show
     (list (cons "attempts" (cons 92 (roost-gallery--copy 'attempts "first attempt" 92)))
           (cons "a new task's draft" (cons 92 (roost-gallery--copy 'draft "running" 92)))))
    (roost-gallery--capture (format "%sattempts-draft.png" out))
    (roost-gallery--show
     (list (cons "search" (cons 92 (roost-gallery--copy 'search "running" 92)))
           (cons "workload" (cons 92 (roost-gallery--copy 'workload "running" 92)))))
    (roost-gallery--capture (format "%ssearch-workload.png" out))
    ;; The dashboard shows every state at once, and so does the sidebar,
    ;; here at the widths it is most often kept at.
    (roost-gallery--show
     (list (cons "dashboard" (cons 180 (roost-gallery--copy 'dashboard "permission" 180))))
     t)
    (roost-gallery--capture (format "%sdashboard.png" out))
    (roost-gallery--show
     (mapcar (lambda (width)
               ;; It fits the window it is in, so in a frame that wide.
               (set-frame-size nil (1+ width) 52)
               (cons (format "sidebar, %d columns" width)
                     (cons width (prog1 (roost-gallery--copy 'sidebar "permission" width)
                                   (set-frame-size nil 190 52)))))
             '(30 38 48))
     t)
    (roost-gallery--capture (format "%ssidebar.png" out))
    (message "Roost's gallery is in %s" out)
    (kill-emacs 0)))

(provide 'gallery)
;;; gallery.el ends here
