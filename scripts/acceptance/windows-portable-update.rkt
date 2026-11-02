#lang racket/base

;; Execute the real generated update helper on Windows with disposable native
;; executables. This proves copy/OS-launch failure recovery, not GUI health,
;; signed-feed discovery or a released MoveBit N-to-N+1 upgrade.
(require rackunit
         rackunit/text-ui
         racket/file
         racket/path
         racket/port
         racket/system
         (prefix-in upd: "../../racket/movebit/update.rkt"))

(unless (eq? (system-type 'os) 'windows)
  (error 'windows-portable-update "requires native Windows; do not count another OS as a pass"))
(define cmd (find-executable-path "cmd.exe"))
(define csc
  (build-path (or (getenv "WINDIR") "C:\\Windows")
              "Microsoft.NET" "Framework64" "v4.0.30319" "csc.exe"))
(unless (and cmd (file-exists? csc))
  (error 'windows-portable-update "Windows cmd.exe and .NET Framework C# compiler required"))

(define scratch (make-temporary-file "movebit-windows-update-~a" 'directory))
(define (write-text path text)
  (call-with-output-file path (lambda (out) (display text out)) #:exists 'replace))
(define (compile-fixture name)
  (define source (build-path scratch (string-append name ".cs")))
  (define binary (build-path scratch (string-append name ".exe")))
  (write-text source
              (string-append
               "class Fixture { static void Main() { System.IO.File.WriteAllText("
               "System.IO.Path.Combine(System.AppDomain.CurrentDomain.BaseDirectory,"
               "\"launched.txt\"), \"" name "\"); } }"))
  (unless (zero? (system*/exit-code csc "/nologo" "/target:exe"
                                  (string-append "/out:" (path->string binary)) source))
    (error 'windows-portable-update "native fixture compilation failed"))
  binary)
(define old-exe (compile-fixture "old"))
(define new-exe (compile-fixture "new"))

(define (run-helper helper log)
  (call-with-output-file log
    (lambda (out)
      ;; Standard cmd quoting handles a helper path with spaces and '&'.
      (define-values (process stdout stdin stderr)
        (subprocess out #f out cmd 'exact
                    (string-append "\"" (path->string cmd) "\" /d /s /c \"\""
                                   (path->string helper) "\"\"")))
      (close-output-port stdin)
      (unless (sync/timeout 45 process)
        (subprocess-kill process #t)
        (subprocess-wait process)
        (error 'windows-portable-update "helper timed out; log: ~a" log))
      (subprocess-wait process)
      (subprocess-status process))
    #:exists 'replace))

(define (wait-marker path)
  (let loop ([remaining 100])
    (cond [(file-exists? path) (file->string path)]
          [(zero? remaining) (error 'windows-portable-update "restored/updated executable did not run")]
          [else (sleep 0.1) (loop (sub1 remaining))])))

(define (scenario kind)
  (define root (build-path scratch (symbol->string kind)))
  (define install (build-path root "Move Bit & Recovery"))
  (define staged (build-path root "staged payload"))
  (define helper (build-path root "apply update.cmd"))
  (make-directory* install)
  (copy-file old-exe (build-path install "RivetHost.exe"))
  (write-text (build-path install "old-layout.txt") "original distribution")
  (define data (build-path root "user-data.json"))
  (write-text data "{\"disposable\":true}")
  (unless (eq? kind 'copy-failure)
    (make-directory* staged)
    (if (eq? kind 'launch-failure)
        (write-text (build-path staged "RivetHost.exe") "not a Windows executable")
        (copy-file new-exe (build-path staged "RivetHost.exe"))))
  (write-text helper (upd:zip-apply-script (path->string install)
                                        (path->string staged) 2147483646))
  (define code (run-helper helper (build-path root "helper-output.log")))
  (check-equal? code (if (eq? kind 'success) 0 1))
  (check-equal? (wait-marker (build-path install "launched.txt"))
                (if (eq? kind 'success) "new" "old"))
  (check-equal? (file->bytes data) #"{\"disposable\":true}")
  (unless (eq? kind 'success)
    (check-equal? (file->bytes (build-path install "RivetHost.exe"))
                  (file->bytes old-exe))
    (check-equal? (file->string (build-path install "old-layout.txt")) "original distribution")
    (check-regexp-match (if (eq? kind 'launch-failure) #rx"launch failed" #rx"robocopy failed")
                        (file->string (build-path root "update-failed.txt")))))

(define failures
  (run-tests
   (test-suite "Windows portable update helper recovery"
     (test-case "successful copy launches the new executable" (scenario 'success))
     (test-case "invalid updated executable restores and runs the original" (scenario 'launch-failure))
     (test-case "failed copy restores and runs the original" (scenario 'copy-failure)))))
;; Keep failed evidence in the throwaway runner directory for diagnosis.
(if (zero? failures)
    (begin (delete-directory/files scratch)
           (displayln "Windows portable update: native success/copy failure/launch failure recovery PASS"))
    (begin (eprintf "Windows helper failure evidence: ~a\n" scratch) (exit 1)))
