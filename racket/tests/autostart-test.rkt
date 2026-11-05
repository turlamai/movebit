#lang racket/base

;; Login-autostart port tests (Services/AutoStart.cs). File-based platforms are
;; exercised against an isolated home / XDG dir; the Windows registry branch
;; only compiles here (reg.exe does not exist off Windows).

(require rackunit
         racket/file
         racket/path
         racket/string
         "../movebit/autostart.rkt")

(define (with-sandbox proc)
  (define sandbox
    (make-temporary-file "movebit-autostart~a" 'directory))
  (parameterize ([autostart-home sandbox]
                 [autostart-executable-path "/opt/apps/MoveBit Host"])
    (dynamic-wind
      void
      (lambda () (proc sandbox))
      (lambda () (delete-directory/files sandbox #:must-exist? #f)))))

(define (with-xdg proc)
  (define sandbox
    (make-temporary-file "movebit-xdg~a" 'directory))
  (define old-xdg (getenv "XDG_CONFIG_HOME"))
  (putenv "XDG_CONFIG_HOME" (path->string sandbox))
  (dynamic-wind
    void
    (lambda () (proc sandbox))
    (lambda ()
      (if old-xdg
          (putenv "XDG_CONFIG_HOME" old-xdg)
          (putenv "XDG_CONFIG_HOME" ""))
      (delete-directory/files sandbox #:must-exist? #f))))

(define (xdg-entry-path xdg)
  (build-path xdg "autostart" "movebit.desktop"))

(case (system-type)
  [(macosx)
   ;; --- macOS LaunchAgent ---------------------------------------------------

   (with-sandbox
    (lambda (sandbox)
      (check-false (autostart-enabled?))
      (set-autostart! #t)
      (define plist
        (build-path sandbox "Library" "LaunchAgents"
                    "com.turlamai.movebit.plist"))
      (check-true (file-exists? plist))
      (check-true (autostart-enabled?))
      (define text (file->string plist))
      (check-true (string-contains? text "com.turlamai.movebit"))
      (check-false (string-contains? text "turinglambdaai"))
      (check-true (string-contains? text "<key>RunAtLoad</key><true/>"))
      (check-true (string-contains? text "<string>/opt/apps/MoveBit Host</string>"))
      (set-autostart! #f)
      (check-false (file-exists? plist))
      (check-false (autostart-enabled?))))

   ;; #128: an install created before the owner rename keeps autostart on by
   ;; migrating the retired label to the canonical one.
   (with-sandbox
    (lambda (sandbox)
      (define dir (build-path sandbox "Library" "LaunchAgents"))
      (make-directory* dir)
      (define old (build-path dir "com.turinglambdaai.movebit.plist"))
      (define new (build-path dir "com.turlamai.movebit.plist"))
      (call-with-output-file old
        (lambda (out) (display "<plist>legacy</plist>" out)))
      ;; Before migration the legacy file alone is not "enabled" under the
      ;; canonical label.
      (check-false (autostart-enabled?))
      (migrate-launch-agent!)
      (check-true (file-exists? new))
      (check-false (file-exists? old))
      (check-true (autostart-enabled?))
      (define text (file->string new))
      (check-true (string-contains? text "com.turlamai.movebit"))
      (check-true (string-contains? text "/opt/apps/MoveBit Host"))
      ;; Idempotent: a second run must not disturb the canonical agent.
      (migrate-launch-agent!)
      (check-true (file-exists? new))
      (check-equal? (file->string new) text)
      (check-false (file-exists? old))))

   ;; An install that already has the canonical agent must not be rewritten;
   ;; the stale legacy file is simply removed.
   (with-sandbox
    (lambda (sandbox)
      (define dir (build-path sandbox "Library" "LaunchAgents"))
      (make-directory* dir)
      (define old (build-path dir "com.turinglambdaai.movebit.plist"))
      (define new (build-path dir "com.turlamai.movebit.plist"))
      (call-with-output-file old
        (lambda (out) (display "<plist>legacy</plist>" out)))
      (call-with-output-file new
        (lambda (out) (display "<plist>canonical</plist>" out)))
      (migrate-launch-agent!)
      (check-true (file-exists? new))
      (check-equal? (file->string new) "<plist>canonical</plist>")
      (check-false (file-exists? old))))]

  [(windows)
   ;; --- Windows HKCU Run key ------------------------------------------------
   ;; Read-only check only: the toggle writes the runner's real registry, so
   ;; it is verified by inspection plus the advapi32 signature (the FFI
   ;; mirrors AutoStart.cs: quoted exe path under the Run key).

   (with-sandbox
    (lambda (_)
      ;; enabled? never throws, whatever the registry says.
      (check-true (let ([v (autostart-enabled?)]) (boolean? v)))))]

  [else
   ;; --- Linux XDG autostart -------------------------------------------------

   (with-sandbox
    (lambda (_)
      (with-xdg
       (lambda (xdg)
         (check-false (autostart-enabled?))
         (set-autostart! #t)
         (check-true (file-exists? (xdg-entry-path xdg)))
         (check-true (autostart-enabled?))
         (define text (file->string (xdg-entry-path xdg)))
         (check-true (string-contains? text "[Desktop Entry]"))
         (check-true
          (string-contains? text "Exec=\"/opt/apps/MoveBit Host\""))
         (check-true
          (string-contains? text "X-GNOME-Autostart-enabled=true"))
         (set-autostart! #f)
         (check-false (file-exists? (xdg-entry-path xdg)))
         (check-false (autostart-enabled?))))))

   ;; Exec quoting escapes the desktop-entry metacharacters ($, ", `, \).
   (with-sandbox
    (lambda (_)
      (parameterize ([autostart-executable-path "/opt/a\"b\\c`d$e"])
        (with-xdg
         (lambda (xdg)
           (set-autostart! #t)
           (define text (file->string (xdg-entry-path xdg)))
           (check-true
            (string-contains?
             text
             "Exec=\"/opt/a\\\"b\\\\c\\`d\\$e\""))
           (set-autostart! #f))))))])
