;;; coder-test.el --- Tests of coder.el -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Clay Sheaff
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; coder.el's requests, against a transport of the tests' own in place
;; of scripts/coder_client.py, which test/test_coder_client.py tests
;; against an HTTP server answering as Coder's API.

;;; Code:
(require 'ert)
(require 'coder)

(defconst coder-test--transport
  "import json, sys, time
action = sys.argv[1]
request = json.loads(sys.stdin.read() or '{}')
if action == 'echo':
    print(json.dumps(dict(ok=True, result=dict(action=action, request=request, argv=sys.argv[2:]))))
elif action == 'refused':
    print(json.dumps(dict(ok=False, error='Coder said 403: no')))
    sys.exit(1)
elif action == 'garbage':
    print('Traceback (most recent call last): oops')
    sys.exit(1)
elif action == 'slow':
    time.sleep(10)
"
  "A transport that does what its action says.")

(defmacro coder-test--with-client (client &rest body)
  "Run BODY with CLIENT bound to a client of a transport of the tests'."
  (declare (indent 1))
  (let ((directory (make-symbol "directory")))
    `(let* ((,directory (make-temp-file "coder-test" t))
            (,client (coder-connect "https://coder.example.org" (expand-file-name "token" ,directory)
                                    '("coder") (expand-file-name "client" ,directory))))
       (unwind-protect
           (progn
             (setf (coder-client-transport ,client) (expand-file-name "transport.py" ,directory))
             (with-temp-file (coder-client-transport ,client) (insert coder-test--transport))
             ,@body)
         (delete-directory ,directory t)))))

(defun coder-test--until (predicate &optional seconds)
  "Wait up to SECONDS, 10 unless given, for PREDICATE to be non-nil."
  (let ((deadline (+ (float-time) (or seconds 10))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(ert-deftest coder-connect-keeps-one-private-connection-per-directory ()
  (let ((directory (make-temp-file "coder-test" t)))
    (unwind-protect
        (let* ((place (expand-file-name "client" directory))
               (client (coder-connect "https://coder.example.org" "~/token" '("coder") place))
               (file (coder-client-configuration client)))
          (should (= (file-modes place) #o700))
          (should (= (file-modes file) #o600))
          (should (equal (json-parse-string (with-temp-buffer (insert-file-contents file) (buffer-string))
                                            :object-type 'alist :array-type 'list)
                         `((url . "https://coder.example.org") (tokenFile . ,(expand-file-name "~/token"))
                           (command . ("coder")))))
          (should (string-suffix-p "scripts/coder_client.py" (coder-client-transport client)))
          ;; The same one again is the same; another is refused, not written over.
          (should (equal (coder-client-configuration
                          (coder-connect "https://coder.example.org" "~/token" '("coder") place))
                         file))
          (should-error (coder-connect "https://other.example.org" "~/token" '("coder") place)
                        :type 'user-error)
          (should-error (coder-connect "https://coder.example.org" "~/token" "coder ssh" place)
                        :type 'user-error))
      (delete-directory directory t))))

(ert-deftest coder-request-gives-its-reply-and-the-connection-to-the-transport ()
  (coder-test--with-client client
    (let (reply failed)
      (coder-request client "echo" '((workspace . "w1") (values . ["a" "b"]))
                     (lambda (result) (setq reply result))
                     (lambda (problem) (setq failed problem)))
      (should (coder-test--until (lambda () (or reply failed))))
      (should-not failed)
      (should (equal (alist-get 'request reply) '((workspace . "w1") (values . ("a" "b")))))
      (should (equal (alist-get 'argv reply) (list (coder-client-configuration client)))))))

(ert-deftest coder-request-says-what-failed ()
  (coder-test--with-client client
    (let (failures)
      (dolist (action '("refused" "garbage"))
        (coder-request client action nil (lambda (_) (ert-fail "succeeded"))
                       (lambda (problem) (push problem failures))))
      (should (coder-test--until (lambda () (= (length failures) 2))))
      (should (member "Coder said 403: no" failures))
      (should (seq-some (lambda (problem) (string-match-p "client failed: Traceback" problem)) failures)))))

(ert-deftest coder-request-errors-in-callbacks-are-their-own ()
  ;; An error in SUCCESS is not the request failing: FAILURE isn't called,
  ;; and the error is signalled as SUCCESS's.  With `debug-on-error', as
  ;; in a test, it reaches whoever waited for the process.
  (coder-test--with-client client
    (let ((debug-on-error t) succeeded failed)
      (coder-request client "echo" nil
                     (lambda (_) (setq succeeded t) (error "A bug of the caller"))
                     (lambda (_) (setq failed t)))
      (should (equal (cadr (should-error (coder-test--until (lambda () succeeded)))) "A bug of the caller"))
      (coder-test--until #'ignore 0.3)
      (should-not failed))))

(ert-deftest coder-request-times-out-and-can-be-cancelled ()
  (coder-test--with-client client
    (let (failed called)
      (let ((request (coder-request client "slow" nil (lambda (_) (ert-fail "succeeded"))
                                    (lambda (problem) (setq failed problem)) 0.5)))
        (should (coder-test--until (lambda () failed) 5))
        (should (string-match-p "didn't answer in" failed))
        (should-not (process-live-p request))
        (should-not (buffer-live-p (process-buffer request))))
      (let ((request (coder-request client "slow" nil (lambda (_) (setq called t)) (lambda (_) (setq called t)))))
        (coder-cancel request)
        (should-not (process-live-p request))
        (should-not (buffer-live-p (process-buffer request)))
        ;; Neither then, nor once its timeout would have come.
        (coder-test--until #'ignore 0.3)
        (should-not called)
        (should-not (memq (process-get request 'coder-timer) timer-list))))))

(ert-deftest coder-request-wait-returns-the-reply-or-a-user-error ()
  (coder-test--with-client client
    (should (equal (alist-get 'action (coder-request-wait client "echo")) "echo"))
    (should (equal (cadr (should-error (coder-request-wait client "refused") :type 'user-error))
                   "Coder said 403: no"))
    (should-error (coder-request-wait client "slow" nil 0.3) :type 'user-error)))

(ert-deftest coder-ssh-configuration-names-its-alias-and-proxies-to-the-workspace ()
  (let ((client (coder--client :configuration "/private/50% off/connection.json"
                               :transport "/lib/coder_client.py")))
    (let ((lines (split-string (coder-ssh-configuration client "0f8c0a43" "task-1") "\n" t)))
      (should (equal (car lines) "Host task-1"))
      (should (equal (cadr lines)
                     (concat "  ProxyCommand python3 -I /lib/coder_client.py ssh "
                             (string-replace "%" "%%" (shell-quote-argument "/private/50% off/connection.json"))
                             " 0f8c0a43"))))
    (should-error (coder-ssh-configuration client "0f8c0a43" "x\n  ProxyCommand evil") :type 'user-error)))

(provide 'coder-test)
;;; coder-test.el ends here
