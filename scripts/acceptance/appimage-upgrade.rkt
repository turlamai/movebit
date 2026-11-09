#lang racket/base

;; Executes the shipped AppImage update path against a real published feed:
;; check the signed manifest, download the next release, verify size/SHA-256,
;; atomically replace the image and keep the previous one. Intended for the
;; upgrade-qualification workflow (see #96); the GUI relaunch is verified by
;; the workflow afterwards.
;;
;; Inputs (environment):
;;   FROM_APPIMAGE      path to the N AppImage (also used as $APPIMAGE)
;;   DATA_DIR           isolated data directory
;;   FEED_URL           signed feed base, e.g. .../download/v0.0.9
;;   EXPECTED_VERSION   N+1 version string
;;   EXPECTED_FROM_SHA  SHA-256 of the N image (hex)
;;   EXPECTED_TO_SHA    SHA-256 of the N+1 image (hex)
;;
;; Prints one JSON object on success and exits non-zero on any mismatch.

(require crypto
         json
         racket/file
         racket/format
         (prefix-in upd: "../../racket/movebit/update.rkt"))

(define (need name)
  (or (getenv name)
      (error 'appimage-upgrade "~a is not set" name)))

(define from (need "FROM_APPIMAGE"))
(define data (need "DATA_DIR"))
(define feed (need "FEED_URL"))
(define expected-version (need "EXPECTED_VERSION"))
(define expected-from-sha (string-downcase (need "EXPECTED_FROM_SHA")))
(define expected-to-sha (string-downcase (need "EXPECTED_TO_SHA")))

(define (sha256-file path)
  (bytes->hex-string (sha256-bytes (file->bytes path))))

(define (fail fmt . args)
  (error 'appimage-upgrade (string-append fmt "~nstate: ~a")
         (apply format fmt args)
         (upd:update-state-snapshot)))

(putenv "APPIMAGE" from)

(define checked (upd:perform-check! feed))
(eprintf "check: ~a~n" checked)
(unless (equal? (hash-ref checked 'status #f) "available")
  (fail "feed did not offer an update: ~a" checked))
(unless (equal? (hash-ref checked 'availableVersion #f) expected-version)
  (fail "expected version ~a, feed offered ~a"
        expected-version (hash-ref checked 'availableVersion #f)))

(upd:start-download! data)
(define phase
  (let loop ([n 0])
    (define s (upd:update-state-snapshot))
    (define p (hash-ref s 'phase #f))
    (cond
      [(member p '("downloaded" "error")) p]
      [(> n 900) p]
      [else (sleep 0.1) (loop (add1 n))])))
(unless (equal? phase "downloaded")
  (fail "download finished in phase ~a" phase))
(define snapshot (upd:update-state-snapshot))
(unless (string? (hash-ref snapshot 'downloadedPath #f))
  (fail "downloadedPath is not a string: ~a" (hash-ref snapshot 'downloadedPath #f)))
(unless (= (hash-ref snapshot 'percent 0) 100)
  (fail "percent is not 100: ~a" (hash-ref snapshot 'percent 0)))

(define from-sha (sha256-file from))
(define to-sha (sha256-file from))
(define previous-path (string-append from ".previous"))
(unless (file-exists? previous-path)
  (fail "no .previous image kept beside ~a" from))
(define previous-sha (sha256-file previous-path))

(unless (equal? to-sha expected-to-sha)
  (fail "replaced image sha ~a != expected N+1 ~a" to-sha expected-to-sha))
(unless (equal? previous-sha expected-from-sha)
  (fail "previous image sha ~a != expected N ~a" previous-sha expected-from-sha))

;; Replay the older signed feed as the already-upgraded version: a real
;; downgrade must be refused, not offered again.
(define downgrade-status
  (let ([feed (getenv "DOWNGRADE_FEED_URL")])
    (and feed
         (parameterize ([upd:current-update-version expected-version])
           (define checked (upd:perform-check! feed))
           (hash-ref checked 'status #f)))))
(when (and (getenv "DOWNGRADE_FEED_URL")
           (not (equal? downgrade-status "up-to-date")))
  (fail "older signed feed was not refused: ~a" downgrade-status))

(define result
  (hasheq 'phase phase
          'downgradeStatus downgrade-status
          'availableVersion (hash-ref snapshot 'availableVersion #f)
          'downloadedPath (hash-ref snapshot 'downloadedPath #f)
          'replacedSha256 to-sha
          'previousSha256 previous-sha))
(define output-json (getenv "OUTPUT_JSON"))
(if output-json
    (call-with-output-file output-json
      (lambda (out) (write-json result out) (newline out))
      #:exists 'truncate)
    (displayln (jsexpr->string result)))
