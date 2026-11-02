#lang racket/base
;; Native x64/arm64 release acceptance: exercise the real Rivet-created
;; AppImage bytes through a throwaway Ed25519-authenticated update candidate,
;; verified loopback HTTPS transport, bounded hash/size verification, atomic replacement,
;; recoverable .previous image, and a post-update runtime launch.
;;
;; No production signing key, published release or external network required.
(require crypto
         crypto/all
         rackunit
         net/url
         net/url-connect
         openssl
         rackunit/text-ui
         rivet/distribution
         racket/file
         racket/path
         racket/string
         racket/system
         (prefix-in upd: "../../racket/movebit/update.rkt"))

(use-all-factories!)

(define args (current-command-line-arguments))
(unless (= (vector-length args) 1)
  (error 'appimage-release-acceptance
         "usage: racket appimage-release-acceptance.rkt <built.AppImage>"))
(unless (eq? (upd:platform-symbol) 'linux)
  (error 'appimage-release-acceptance "must run on native Linux"))
(define image (path->complete-path (vector-ref args 0)))
(unless (and (file-exists? image) (> (file-size image) 0))
  (error 'appimage-release-acceptance "built AppImage is missing or empty"))
(define source-digest (sha256-file/hex image))
(define source-size (file-size image))
(define source-bytes (file->bytes image))

(define scratch (make-temporary-file "movebit-real-appimage-~a" 'directory))
(define installed (build-path scratch "MoveBit.AppImage"))
(copy-file image installed)
(file-or-directory-permissions installed #o755)
(define old-appimage (getenv "APPIMAGE"))

;; Serve the actual AppImage over loopback HTTPS with an ephemeral, trusted
;; test-only certificate. Rivet correctly rejects HTTP artifact URLs in a
;; signed manifest; do not relax that release security boundary for tests.
;; The signed SHA-256 and size still authenticate the downloaded bytes.
(define openssl-exe (find-executable-path "openssl"))
(unless openssl-exe
  (error 'appimage-release-acceptance "openssl is required for local HTTPS acceptance"))
(define cert (build-path scratch "loopback-cert.pem"))
(define key (build-path scratch "loopback-key.pem"))
(unless (zero? (system*/exit-code openssl-exe
                                  "req" "-x509" "-newkey" "rsa:2048" "-nodes"
                                  "-days" "1" "-subj" "/CN=localhost"
                                  "-addext" "subjectAltName=IP:127.0.0.1,DNS:localhost"
                                  "-keyout" (path->string key)
                                  "-out" (path->string cert)))
  (error 'appimage-release-acceptance "failed to create ephemeral loopback TLS certificate"))
(define server-context
  (ssl-make-server-context 'secure
                           #:private-key (list 'pem (path->string key))
                           #:certificate-chain (path->string cert)))
(define client-context
  (parameterize ([ssl-default-verify-sources (list (path->string cert))])
    (ssl-secure-client-context)))
(define listener (ssl-listen 0 8 #f "127.0.0.1" server-context))
(define-values (_addr port _peer _p) (ssl-addresses listener #t))
(define server
  (thread
   (lambda ()
     (let loop ()
       (define-values (in out) (ssl-accept listener))
       (thread
        (lambda ()
          (with-handlers ([exn:fail? (lambda (_) (void))])
            (read-line in 'any)
            (let consume ()
              (define line (read-line in 'any))
              (unless (or (eof-object? line) (string=? (string-trim line) ""))
                (consume)))
            (fprintf out "HTTP/1.0 200 OK\r\nContent-Length: ~a\r\n\r\n" source-size)
            (write-bytes source-bytes out)
            (flush-output out))
          (close-output-port out)
          (close-input-port in)))
       (loop)))))

(define priv (generate-private-key 'eddsa '((curve ed25519))))
(define pub (datum->pk-key (pk-key->datum priv 'rkt-public) 'rkt-public))
(define component-tail
  (if (equal? (procedure-arity updater-config) 10) (list #f) '()))
(define config
  (apply updater-config "site.jrtx.movebit" "0.1.0" 'stable
         'linux (upd:architecture-symbol) pub "movebit-native-test" 0
         (* 512 1024 1024) component-tail))

(define (signed-candidate digest size)
  (define artifact
    (apply update-artifact 'linux (upd:architecture-symbol)
           (format "https://127.0.0.1:~a/release.AppImage" port)
           digest size 'appimage '() component-tail))
  (define inner
    (update-manifest "site.jrtx.movebit" "9.9.9" 7 'stable
                     "2026-10-10T00:00:00Z" "0.0.0" #f #t 100
                     (list artifact)))
  (define output (open-output-bytes))
  (write-signed-manifest inner priv "movebit-native-test" output)
  (define verified
    (verify-signed-manifest (open-input-bytes (get-output-bytes output))
                            pub #:key-id "movebit-native-test"))
  (define selected (select-update config verified #:install-kind 'appimage))
  (check-true (update-candidate? selected))
  selected)

;; Preserve normal certificate-chain and hostname verification while
;; trusting only this ephemeral test certificate, never a production key.
(define (download-local! candidate)
  (parameterize ([current-https-protocol client-context])
    (upd:download-appimage-with-progress! candidate)))

;; run-tests reports a nonzero failure count; a raw top-level rackunit
;; check can print FAILURE but leave the process exit code at zero.
(define failures
  (run-tests
   (test-suite
    "native AppImage release upgrade"
    (test-case "signed real-byte in-place update and rollback backup"
     (dynamic-wind
  (lambda () (putenv "APPIMAGE" (path->string installed)))
  (lambda ()
    (define original-digest (sha256-file/hex installed))
    (check-equal? original-digest source-digest)
    ;; Both rejection paths must leave the original launchable image intact.
    (check-exn exn:fail?
               (lambda ()
                 (download-local!
                  (signed-candidate (make-string 64 #\0) source-size))))
    (check-equal? (sha256-file/hex installed) original-digest)
    (check-exn exn:fail?
               (lambda ()
                 (download-local!
                  (signed-candidate source-digest (sub1 source-size)))))
    (check-equal? (sha256-file/hex installed) original-digest)
    (check-false (file-exists? (string-append (path->string installed) ".previous")))

    (let ([updated (download-local!
                    (signed-candidate source-digest source-size))]
          [backup (string-append (path->string installed) ".previous")])
      (check-equal? updated (path->string installed))
      (check-equal? (sha256-file/hex installed) source-digest)
      (check-equal? (file-size installed) source-size)
      (check-equal? (hash-ref (upd:update-state-snapshot) 'percent) 100)
      (check-true (file-exists? backup))
      (check-equal? (sha256-file/hex backup) original-digest)
      (check-not-false (memq 'execute (file-or-directory-permissions installed #f)))
      ;; The installed path itself still executes a valid AppImage runtime.
      (unless (zero? (system*/exit-code installed "--appimage-version"))
        (error 'appimage-release-acceptance "updated AppImage failed runtime launch"))
      (printf "native ~a AppImage: signed real-byte download, tamper/size rejection, atomic swap, backup, relaunch PASS~%"
              (upd:architecture-symbol))))
  (lambda ()
    (putenv "APPIMAGE" (or old-appimage ""))
    (void)))))))
;; rackunit runs test cases under a dedicated custodian. The server thread was
;; created by the outer custodian, so killing it from inside the test raises
;; "the current custodian does not solely manage the specified thread".
;; Clean up from the owning outer custodian after run-tests has returned.
(kill-thread server)
(ssl-close listener)
(delete-directory/files scratch)
(unless (zero? failures) (exit 1))
