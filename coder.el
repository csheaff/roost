;;; coder.el --- A small client for Coder workspaces -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Clay Sheaff
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Coder's workspaces from Emacs, for a package that runs things in them:
;; templates and their parameters, a workspace's state, starting and
;; stopping it, and SSH into it through the Coder CLI with autostart off.
;; It keeps nothing of its own but the connection: what to keep of the
;; workspaces, when to ask and what to do with them is its caller's.
;;
;; A request runs scripts/coder_client.py, Python 3.9's standard library,
;; which reads the token from a private file, so the token is never in an
;; argument, a buffer or this Emacs's memory, and asks Coder's REST API.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defconst coder--directory (file-name-directory (or load-file-name buffer-file-name))
  "Where coder.el is, with scripts/coder_client.py below it.")

(cl-defstruct (coder-client (:constructor coder--client) (:copier nil))
  "A connection to one Coder deployment.
CONFIGURATION is the private file naming its URL, token file and CLI;
TRANSPORT is the Python file that reads it."
  configuration transport)

(defun coder-connect (url token-file command directory)
  "A client of the Coder at URL, with the token in TOKEN-FILE and CLI COMMAND.
COMMAND is the CLI's argv, such as (\"/usr/local/bin/coder\"), not a
shell command.  The connection is kept in DIRECTORY, a private local
directory of its own, which the CLI's configuration goes in too: one
DIRECTORY, one connection.  Connecting writes only there, and asks
nothing of Coder; `coder-request' with \"validate\" does."
  (unless (and (stringp url) (stringp token-file) (consp command) (seq-every-p #'stringp command))
    (user-error "Give Coder a URL, a token file and the CLI as a list of strings"))
  (when (file-remote-p directory) (user-error "Keep the Coder connection on this machine"))
  (setq directory (file-name-as-directory (expand-file-name directory)))
  (make-directory directory t)
  (set-file-modes directory #o700)
  (let ((file (expand-file-name "connection.json" directory))
        (text (json-serialize `((url . ,url) (tokenFile . ,(expand-file-name token-file))
                                (command . ,(vconcat command))))))
    (unless (and (file-exists-p file)
                 (equal text (with-temp-buffer (insert-file-contents file) (string-trim (buffer-string)))))
      (when (file-exists-p file)
        (user-error "%s holds another Coder connection: give this one a directory of its own" directory))
      (let ((temporary (make-temp-file (expand-file-name ".connection-" directory))))
        (unwind-protect
            (progn (set-file-modes temporary #o600)
                   (with-temp-file temporary (insert text))
                   (rename-file temporary file t))
          (when (file-exists-p temporary) (delete-file temporary)))))
    (coder--client :configuration file
                   :transport (expand-file-name "scripts/coder_client.py" coder--directory))))

(defun coder--argv (client action &rest arguments)
  "The argv running CLIENT's ACTION, with ARGUMENTS after its connection."
  (append (list "python3" "-I" (coder-client-transport client) action (coder-client-configuration client))
          arguments))

(defun coder--reply (output status)
  "The outcome of a request whose process said OUTPUT and exited with STATUS.
\(ok . RESULT) or (failed . MESSAGE)."
  (let ((reply (ignore-errors
                 (json-parse-string (car (last (split-string output "\n" t "[ \t\r]+")))
                                    :object-type 'alist :array-type 'list
                                    :null-object nil :false-object nil))))
    (cond ((and (consp reply) (eq (alist-get 'ok reply) t) (eql status 0))
           (cons 'ok (alist-get 'result reply)))
          ((and (consp reply) (stringp (alist-get 'error reply)))
           (cons 'failed (alist-get 'error reply)))
          (t (cons 'failed (format "The Coder client failed%s"
                                   (if (string-empty-p (string-trim output)) ""
                                     (concat ": " (truncate-string-to-width (string-trim output) 300)))))))))

(defun coder-request (client action parameters success &optional failure timeout)
  "Ask CLIENT's Coder ACTION, with PARAMETERS, an alist, and don't wait.
SUCCESS is called with Coder's reply, decoded, and FAILURE, or else
`message', with what went wrong.  After TIMEOUT seconds, 30 unless
given, FAILURE is called and the request stopped: Coder may still do
what it was asked, such as start a build.  An error in SUCCESS or
FAILURE is its own, signalled, not taken for the request's.

Return the request's process, which `coder-cancel' stops without
calling either."
  (let* ((failure (or failure (lambda (problem) (message "Coder: %s" problem))))
         (input (if parameters (json-encode parameters) "{}"))
         (output (generate-new-buffer " *coder*" t))
         (default-directory temporary-file-directory)
         process timer)
    (when (> (string-bytes input) 65536)
      (kill-buffer output)
      (user-error "This Coder request is over 64 KiB"))
    (setq process
          (condition-case err
              (make-process
               :name "coder" :buffer output :noquery t :connection-type 'pipe
               :coding 'utf-8-unix :command (coder--argv client action)
               :sentinel
               (lambda (process _event)
                 (when (and (memq (process-status process) '(exit signal))
                            (not (process-get process 'coder-done)))
                   (process-put process 'coder-done t)
                   (when timer (cancel-timer timer))
                   (let ((outcome (coder--reply (with-current-buffer output (buffer-string))
                                                (process-exit-status process))))
                     (kill-buffer output)
                     (if (eq (car outcome) 'ok)
                         (funcall success (cdr outcome))
                       (funcall failure (cdr outcome)))))))
            (error (kill-buffer output) (signal (car err) (cdr err)))))
    (setq timer (run-at-time (or timeout 30) nil
                             (lambda ()
                               (when (and (process-live-p process) (not (process-get process 'coder-done)))
                                 (coder-cancel process)
                                 (funcall failure (format "Coder didn't answer in %ds" (or timeout 30)))))))
    (process-put process 'coder-timer timer)
    ;; One that has already exited says why in its output.
    (ignore-error error
      (process-send-string process input)
      (process-send-eof process))
    process))

(defun coder-cancel (request)
  "Stop REQUEST, a process `coder-request' returned, calling nothing.
What Coder was asked to do may happen all the same."
  (unless (process-get request 'coder-done)
    (process-put request 'coder-done t)
    (when (timerp (process-get request 'coder-timer)) (cancel-timer (process-get request 'coder-timer)))
    (let ((buffer (process-buffer request)))
      (delete-process request)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun coder-request-wait (client action &optional parameters timeout)
  "Ask CLIENT's Coder ACTION with PARAMETERS, and return its reply.
For what a question needs before it is asked; \\[keyboard-quit] stops
waiting.  A failure is a `user-error'."
  (let* ((done nil) (result nil) (problem nil)
         (request (coder-request client action parameters
                                 (lambda (value) (setq result value done t))
                                 (lambda (message) (setq problem message done t))
                                 timeout)))
    (unwind-protect
        (while (not done) (accept-process-output request 0.05))
      (unless done (coder-cancel request)))
    (if problem (user-error "%s" problem) result)))

(defun coder-templates (client organization success &optional failure)
  "Call SUCCESS with CLIENT's templates in ORGANIZATION, an ID."
  (coder-request client "templates" `((organization . ,organization)) success failure))

(defun coder-template (client template success &optional failure)
  "Call SUCCESS with TEMPLATE's active version and the parameters it publishes.
The reply is an alist of `template', `version', its ID, and
`parameters', as Coder gives them."
  (coder-request client "template" `((template . ,template)) success failure))

(defun coder-workspace-create (client name version parameters success &optional failure ttl)
  "Create workspace NAME for CLIENT from template VERSION and PARAMETERS.
PARAMETERS is a list of alists of `name' and `value'.  TTL is the
milliseconds it may run before Coder stops it; 0 is never, and nil the
template's choice.  SUCCESS gets the workspace once Coder has queued its
first build, not when it runs."
  (coder-request client "create" `((name . ,name) (version . ,version) (parameters . ,(vconcat parameters))
                                   ,@(when ttl `((ttl . ,ttl))))
                 success failure))

(defun coder-workspace (client workspace success &optional failure)
  "Call SUCCESS with WORKSPACE, an ID, as Coder has it; never starts it."
  (coder-request client "workspace" `((id . ,workspace)) success failure))

(defun coder-workspace-start (client workspace success &optional failure)
  "Ask CLIENT's Coder to start WORKSPACE; SUCCESS gets its build, queued."
  (coder-request client "start" `((workspace . ,workspace)) success failure))

(defun coder-workspace-stop (client workspace success &optional failure)
  "Ask CLIENT's Coder to stop WORKSPACE; SUCCESS gets its build, queued.
Everything running in it stops; whether to is the caller's to decide."
  (coder-request client "stop" `((workspace . ,workspace)) success failure))

(defun coder-ssh-command (client workspace)
  "The argv of a stdio proxy into CLIENT's WORKSPACE, an ID, for SSH.
It refuses a workspace that isn't running, rather than start it."
  (coder--argv client "ssh" workspace))

(defun coder-ssh-configuration (client workspace alias)
  "An SSH configuration stanza for ALIAS, reaching CLIENT's WORKSPACE.
Where it goes is the caller's choice: nothing is installed."
  (unless (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._-]*\\'" alias) (user-error "Invalid SSH alias %S" alias))
  (unless (string-match-p "\\`[0-9a-fA-F-]+\\'" workspace) (user-error "Invalid workspace ID %S" workspace))
  (format "Host %s\n  ProxyCommand %s\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  ConnectTimeout 8\n"
          alias (string-replace "%" "%%" (mapconcat #'shell-quote-argument (coder-ssh-command client workspace) " "))))

(provide 'coder)
;;; coder.el ends here
