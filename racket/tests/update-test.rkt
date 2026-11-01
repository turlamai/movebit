#lang racket/base

;; Update-flow tests on the rivet/distribution engine (the threadly
;; test-suite shape, ported): the offline trust chain — craft a manifest,
;; sign it with a throwaway Ed25519 key, verify it, and select updates the
;; same way the live checker does — then the REAL download paths against a
;; local TCP server: the manifest-verified chain into the swap chain
;; (chmod -> rename -> staged apply helper via prepare-install!), the
;; AppImage sibling-asset flow with its sidecar checksum, the persistent
;; 4-hour silent-check throttle stamp, and the failed-check contract
;; against an unreachable feed.
;;
;; (fetch-update-manifest itself only accepts HTTPS, so the live-feed
;; signature compatibility of the embedded key is the release pipeline's
;; job; perform-check! against a real feed is production traffic.)

(require crypto
         crypto/all
         json
         rackunit
         rivet/distribution
         racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         racket/tcp
         (file "../movebit/paths.rkt")
         (prefix-in upd: "../movebit/update.rkt"))

(use-all-factories!)

;; Every persistent touch lands in a throwaway home: the bootstrap (the
;; per-machine stamp store) and the update data dir.
(define test-home (make-temporary-file "movebit-updater-home-~a" 'directory))
(putenv "MOVEBIT_BOOTSTRAP_DIR" (path->string test-home))
(define test-data-dir (make-temporary-file "movebit-updater-data-~a" 'directory))

(define download-limit (* 512 1024 1024))

;; Rivet main grew a trailing `component` discriminator on updater-config and
;; update-artifact; the release pin (v0.11.0) predates it. Fixtures carry the
;; plain component-less artifact (#f) either way (see movebit/update.rkt).
(define component-tail
  (if (equal? (procedure-arity updater-config) 10) (list #f) '()))

;; ---- platform identity ------------------------------------------------------

(test-case "platform symbols match rivet release manifests"
  (case (system-type 'os)
    [(macosx) (check-equal? (upd:platform-symbol) 'macos)]
    [(windows) (check-equal? (upd:platform-symbol) 'windows)]
    [else (check-equal? (upd:platform-symbol) 'linux)])
  (check-not-false (memq (upd:architecture-symbol) '(arm64 x64))))

;; ---- embedded release identity ----------------------------------------------

(test-case "embedded identity is coherent and the key is configured"
  (check-true (upd:movebit-update-configured?))
  (check-equal? upd:update-key-id "movebit-2026-10")
  (check-equal? upd:default-update-base-url
                "https://github.com/turinglambdaai/movebit/releases/latest/download"))

;; ---- AppImage sibling-asset derivation ----------------------------------------

;; The feed's linux entry and the sibling .AppImage release asset share the
;; release-contract arch spelling (x64|arm64), so the derivation is only the
;; extension swap.
(test-case "appimage asset derivation swaps the extension"
  (check-equal? (upd:appimage-asset-name "movebit-0.3.1-linux-x64.tar.gz")
                "movebit-0.3.1-linux-x64.AppImage")
  (check-equal? (upd:appimage-asset-name "movebit-1.0.0-linux-arm64.tar.gz")
                "movebit-1.0.0-linux-arm64.AppImage")
  ;; A non-tar.gz feed entry cannot derive a sibling — refuse loudly.
  (check-exn exn:fail?
             (lambda () (upd:appimage-asset-name "movebit-0.3.1-windows-x64.zip"))))

;; ---- offline trust chain (throwaway keypair, same DER shapes the
;; ---- release pipeline uses) ------------------------------------------------------

(define priv (generate-private-key 'eddsa '((curve ed25519))))
(define pub (datum->pk-key (pk-key->datum priv 'rkt-public) 'rkt-public))

;; The install layout a staged payload must carry: macOS zips movebit.app,
;; Windows zips ARE the install layout (RivetHost.exe at the root).
(define payload-layout
  (case (system-type 'os)
    [(macosx) '("MoveBit.app" "Contents" "MacOS" "MoveBit")]
    [else '("RivetHost.exe")]))
(define payload-root-name (first payload-layout))

(define payload-bytes (make-bytes 300000 42))
(define payload-zip (make-temporary-file "movebit-payload-~a.zip"))
;; `tar` writes the archive; bsdtar (macOS, Windows — the only platforms
;; that ever extract) reads it back by content, so a POSIX tar under a .zip
;; name exercises extract-zip! without a zip writer here. Linux never
;; extracts: prepare-install! refuses there (asserted below).
(let ([staging (make-temporary-file "movebit-payload-src-~a" 'directory)])
  (make-directory* (apply build-path staging (drop-right payload-layout 1)))
  (call-with-output-file (apply build-path staging payload-layout)
    (lambda (out) (write-bytes payload-bytes out)))
  (unless (system* (find-executable-path "tar")
                   "-cf" (path->string payload-zip)
                   "-C" (path->string staging)
                   payload-root-name)
    (error 'update-test "tar could not stage the payload"))
  (delete-directory/files staging))
(define payload-sha256 (sha256-file/hex payload-zip))

;; A manifest whose single artifact points at artifact-url but carries the
;; local payload's signed size + digest.
(define (test-manifest artifact-url)
  (update-manifest
   "site.jrtx.movebit" "9.9.9" 7 'stable
   "2026-10-10T00:00:00Z" "0.0.0" #f #t 100
   (list (apply update-artifact (upd:platform-symbol) (upd:architecture-symbol)
                artifact-url
                payload-sha256
                (file-size payload-zip)
                'zip '()
                component-tail))))

(test-case "signed manifest verifies, a wrong key-id fails closed"
  (define wrapped (open-output-bytes))
  (write-signed-manifest (test-manifest "https://dl.example/movebit-9.9.9.zip")
                         priv "movebit-test" wrapped)
  (define verified
    (verify-signed-manifest (open-input-bytes (get-output-bytes wrapped))
                            pub #:key-id "movebit-test"))
  (check-equal? (update-manifest-version verified) "9.9.9")
  (check-exn exn:fail?
             (lambda ()
               (verify-signed-manifest
                (open-input-bytes (get-output-bytes wrapped))
                pub #:key-id "some-other-key"))))

(test-case "select-update picks this platform's artifact and gates versions"
  (define config
    (apply updater-config "site.jrtx.movebit" "0.0.1" 'stable
           (upd:platform-symbol) (upd:architecture-symbol)
           pub "movebit-test" 0 download-limit
           component-tail))
  (define candidate
    (select-update config
                   (test-manifest "https://dl.example/movebit-9.9.9.zip")))
  (check-true (update-candidate? candidate))
  (check-equal? (update-artifact-size (update-candidate-artifact candidate))
                (file-size payload-zip))
  ;; the same feed at/below the running version selects nothing
  (define current-config
    (struct-copy updater-config config [current-version "9.9.9"]))
  (check-false
   (select-update current-config
                  (test-manifest "https://dl.example/movebit-9.9.9.zip"))))

;; ---- local artifact server ------------------------------------------------------
;; A minimal one-shot HTTP file server: every connection gets the bytes for
;; the path it asked for, so the manifest-verified download and the AppImage
;; sidecar flow can share the same shape.

(define (serve-files! responses)
  ;; responses: (list (cons path-suffix bytes))
  (define listener (tcp-listen 0 16 #f "127.0.0.1"))
  (define-values (_bind-host port-number _peer-host _peer-port)
    (tcp-addresses listener #t))
  (define server
    (thread
     (lambda ()
       (let accept-loop ()
         (define-values (in out) (tcp-accept listener))
         (thread
          (lambda ()
            (define request-line (read-line in 'return-linefeed))
            (define path
              (if (eof-object? request-line)
                  ""
                  (let ([m (regexp-match #px"^\\w+\\s+(\\S+)" request-line)])
                    (if m (second m) ""))))
            (let drain ()
              (define line (read-line in 'return-linefeed))
              (unless (or (eof-object? line) (equal? line "") (equal? line "\r"))
                (drain)))
            (define body
              (for/or ([entry (in-list responses)])
                (and (string-suffix? path (car entry)) (cdr entry))))
            (if body
                (begin
                  (write-string
                   (format "HTTP/1.0 200 OK\r\nContent-Length: ~a\r\n\r\n"
                           (bytes-length body))
                   out)
                  (write-bytes body out))
                (write-string
                 "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n\r\n" out))
            (close-output-port out)
            (close-input-port in)))
         (accept-loop)))))
  (values port-number
          (lambda ()
            (kill-thread server)
            (tcp-close listener))))

;; The download runs on a backend-style worker thread; the test polls the
;; same state box the hosts poll through get-update-state until a terminal
;; phase lands.
(define (wait-for-terminal-phase! timeout-seconds)
  (let loop ([deadline (+ (current-seconds) timeout-seconds)])
    (define phase (hash-ref (upd:update-state-snapshot) 'phase))
    (if (or (equal? phase "downloaded")
            (equal? phase "error")
            (> (current-seconds) deadline))
        phase
        (begin (sleep 0.05) (loop deadline)))))

;; ---- manifest-verified download chain -> prepare-install ------------------------

(test-case "download fetches and verifies, prepare-install stages and writes the helper"
  (define payload (file->bytes payload-zip))
  (define-values (port-number stop-server!)
    (serve-files! (list (cons "/movebit-9.9.9.zip" payload))))
  (define config
    (apply updater-config "site.jrtx.movebit" "0.1.0" 'stable
           (upd:platform-symbol) (upd:architecture-symbol)
           pub "movebit-test" 0 download-limit
           component-tail))
  (define candidate
    (select-update config
                   (test-manifest
                    (format "http://127.0.0.1:~a/movebit-9.9.9.zip" port-number))))
  (check-true (update-candidate? candidate))

  (parameterize ([upd:current-install-dir test-data-dir])
    (upd:reset-update-state!)
    (upd:set-candidate! candidate)
    (upd:start-download! test-data-dir)
    ;; a mismatch here is almost always the payload/manifest digest — show
    ;; the state message next to the phase
    (define phase (wait-for-terminal-phase! 120))
    (check-equal? phase "downloaded"
                  (format "~s" (hash-ref (upd:update-state-snapshot) 'message)))
    (check-equal? (hash-ref (upd:update-state-snapshot) 'percent) 100)
    (define downloaded
      (hash-ref (upd:update-state-snapshot) 'downloadedPath #f))
    (check-true (and downloaded (file-exists? downloaded)))

    (case (upd:platform-symbol)
      [(linux)
       ;; AppImage swaps happen at download time; tarball/package installs
       ;; are manual — prepare-install! refuses honestly. platform-symbol,
       ;; not system-type's os ('unix on Linux — the same trap the module
       ;; had).
       (check-exn exn:fail? (lambda () (upd:prepare-install! test-data-dir)))]
      [else
       (define helper (upd:prepare-install! test-data-dir))
       (check-true (file-exists? helper))
       (check-equal? (hash-ref (upd:update-state-snapshot) 'phase)
                     "ready-to-apply")
       ;; the staged layout must be complete (the helper's swap trusts it)
       (define staged (build-path test-data-dir "updates" "staged"))
       (check-true
        (file-exists?
         (if (eq? (system-type 'os) 'macosx)
             (apply build-path staged payload-layout)
             (build-path staged "RivetHost.exe"))))
       ;; and the helper script must carry its swap recipe
       (check-true
        (string-contains? (file->string helper)
                          (if (eq? (system-type 'os) 'macosx)
                              "STAGED_BUNDLE"
                              "robocopy")))]))

  (stop-server!))

;; ---- AppImage: signed manifest identity, exact payload and atomic swap ----

(test-case "signed AppImage entry is selected only for matching platform and version"
  (define digest (make-string 64 #\\a))
  (define artifact
    (apply update-artifact 'linux (upd:architecture-symbol)
           "https://downloads.example/movebit-9.9.9-linux.AppImage"
           digest 100 'appimage '() component-tail))
  (define manifest
    (update-manifest "site.jrtx.movebit" "9.9.9" 7 'stable
                     "2026-10-10T00:00:00Z" "0.0.0" #f #t 100
                     (list artifact)))
  (define wrapped (open-output-bytes))
  (write-signed-manifest manifest priv "movebit-test" wrapped)
  (define verified
    (verify-signed-manifest (open-input-bytes (get-output-bytes wrapped))
                            pub #:key-id "movebit-test"))
  (define (config platform version)
    (apply updater-config "site.jrtx.movebit" version 'stable
           platform (upd:architecture-symbol) pub "movebit-test" 0
           download-limit component-tail))
  (define selected (select-update (config 'linux "0.1.0") verified
                                  #:install-kind 'appimage))
  (check-true (update-candidate? selected))
  (check-equal? (update-artifact-sha256 (update-candidate-artifact selected)) digest)
  (check-false (select-update (config 'windows "0.1.0") verified
                              #:install-kind 'appimage))
  (check-false (select-update (config 'linux "9.9.9") verified
                              #:install-kind 'appimage))
  (check-false (select-update (config 'linux "10.0.0") verified
                              #:install-kind 'appimage))
  (check-false (select-update (config 'linux "0.1.0")
                              (struct-copy update-manifest verified [artifacts '()])
                              #:install-kind 'appimage)))

(test-case "AppImage rejects tampered payload and size; ignores malicious sidecar"
  (when (eq? (upd:platform-symbol) 'linux)
    (define arch (symbol->string (upd:architecture-symbol)))
    (define asset (format "movebit-9.9.9-linux-~a.AppImage" arch))
    (define payload (make-bytes 65536 7))
    (define tampered (make-bytes 65536 8))
    (define digest (bytes->hex-string (sha256-bytes payload)))
    (define-values (port-number stop-server!)
      (serve-files!
       (list (cons (string-append "/" asset ".sha256")
                   (string->bytes/utf-8
                    (format "~a  ~a\\n" (bytes->hex-string (sha256-bytes tampered)) asset)))
             (cons (string-append "/valid/" asset) payload)
             (cons (string-append "/tampered/" asset) tampered))))
    (define image-dir (make-temporary-file "movebit-appimage-~a" 'directory))
    (define image-path (build-path image-dir "movebit.AppImage"))
    (define original (make-bytes 16 3))
    (call-with-output-file image-path #:exists 'truncate
      (lambda (out) (write-bytes original out)))
    (define old-appimage (getenv "APPIMAGE"))
    (putenv "APPIMAGE" (path->string image-path))
    (define (candidate suffix sha size)
      (define artifact
        (apply update-artifact 'linux (upd:architecture-symbol)
               (format "http://127.0.0.1:~a/~a/~a" port-number suffix asset)
               sha size 'appimage '() component-tail))
      (update-candidate
       (update-manifest "site.jrtx.movebit" "9.9.9" 7 'stable
                        "2026-10-10T00:00:00Z" "0.0.0" #f #t 100
                        (list artifact))
       artifact))
    (dynamic-wind
      void
      (lambda ()
        (check-exn exn:fail?
                   (lambda ()
                     (upd:download-appimage-with-progress!
                      (candidate "tampered" digest (bytes-length payload)))))
        (check-equal? (file->bytes image-path) original)
        (check-exn exn:fail?
                   (lambda ()
                     (upd:download-appimage-with-progress!
                      (candidate "valid" digest (sub1 (bytes-length payload))))))
        (check-equal? (file->bytes image-path) original)
        ;; The sidecar deliberately advertises the tampered hash. A valid
        ;; signed digest still accepts only the exact AppImage bytes.
        (define swapped
          (upd:download-appimage-with-progress!
           (candidate "valid" digest (bytes-length payload))))
        (check-equal? swapped (path->string image-path))
        (check-equal? (sha256-file/hex image-path) digest)
        (check-equal? (hash-ref (upd:update-state-snapshot) 'percent) 100)
        (check-equal? (length (directory-list image-dir)) 1)
        (check-not-false
         (memq 'execute (file-or-directory-permissions image-path #f))))
      (lambda ()
        (putenv "APPIMAGE" (or old-appimage ""))
        (when (file-exists? image-path) (delete-file image-path))
        (delete-directory image-dir)
        (stop-server!)))))

;; ---- persistent silent-check throttle ------------------------------------------

(test-case "the 4-hour throttle stamp is persistent and settled-only"
  (define bootstrap (build-path test-home "bootstrap.json"))
  ;; no stamp yet -> not throttled
  (check-false (upd:update-check-throttled?))
  ;; a settled check (here: the deterministic no-feed-URL refusal) refreshes
  ;; the stamp and lands it in bootstrap.json
  (define result (upd:perform-check! ""))
  (check-equal? (hash-ref result 'status) "error")
  (check-true (upd:update-check-throttled?))
  (define doc (with-input-from-file bootstrap read-json))
  (check-true (exact-integer? (hash-ref doc 'last-update-check)))
  ;; an old stamp does not throttle
  (save-bootstrap (hash-set (load-bootstrap) 'last-update-check 0))
  (check-false (upd:update-check-throttled?)))

(test-case "a transient check failure never refreshes the stamp"
  ;; stamp says "checked recently", then the feed is unreachable
  (upd:record-update-check-stamp!)
  (define before (hash-ref (load-bootstrap) 'last-update-check))
  (define result (upd:perform-check! "https://127.0.0.1:9/movebit"))
  (check-equal? (hash-ref result 'status) "error")
  (check-equal? (hash-ref (upd:update-state-snapshot) 'phase) "error")
  ;; the stamp is untouched — the next launch retries instead of waiting
  (check-equal? (hash-ref (load-bootstrap) 'last-update-check) before))

;; ---- sticky rollout bucket --------------------------------------------------------

(test-case "the rollout bucket is sticky, in range, and self-heals"
  ;; No bucket yet: one is generated, lands in 0..99, and persists.
  (save-bootstrap (hash-set (load-bootstrap) 'rollout-bucket #f))
  (define bucket (upd:rollout-bucket))
  (check-true (and (exact-integer? bucket) (<= 0 bucket 99)))
  (check-equal? (hash-ref (load-bootstrap) 'rollout-bucket) bucket)
  ;; A persisted bucket wins over generation — the cohort is sticky.
  (save-bootstrap (hash-set (load-bootstrap) 'rollout-bucket 42))
  (check-equal? (upd:rollout-bucket) 42)
  ;; A corrupt (out-of-range) bucket regenerates instead of poisoning every
  ;; future check.
  (save-bootstrap (hash-set (load-bootstrap) 'rollout-bucket 100))
  (define healed (upd:rollout-bucket))
  (check-true (and (exact-integer? healed) (<= 0 healed 99))))

;; ---- install shape ------------------------------------------------------------------

(test-case "the install kind follows the platform and the Program Files signal"
  ;; macOS zips are portable; Linux stays unfiltered; Windows decides below.
  (case (upd:platform-symbol)
    [(macos) (check-equal? (upd:install-kind) 'portable)]
    [(linux) (check-false (upd:install-kind))]
    [else (check-not-false (memq (upd:install-kind) '(msi portable)))])
  ;; The Program Files prefix decision (pure): with ProgramFiles set, an
  ;; install under it is the MSI shape and one beside it is not.
  (dynamic-wind
    (lambda () (putenv "ProgramFiles" "C:\\Program Files"))
    (lambda ()
      (check-true (upd:install-dir-under-program-files?
                   "C:\\Program Files\\MoveBit"))
      (check-true (upd:install-dir-under-program-files?
                   "C:\\Program Files\\MoveBit\\"))
      (check-false (upd:install-dir-under-program-files?
                    "C:\\Program Files (other)\\MoveBit"))
      (check-false (upd:install-dir-under-program-files?
                    "D:\\Apps\\MoveBit")))
    (lambda () (putenv "ProgramFiles" "")))
  ;; A dangling signal means no signal at all: NONE of the three variables
  ;; may contribute a prefix (on real Windows runners ProgramFiles(x86) and
  ;; ProgramW6432 exist alongside ProgramFiles — clearing one is not
  ;; clearing the signal). putenv with an empty value unsets on Windows and
  ;; sets an empty string elsewhere; both read back as "no signal".
  (dynamic-wind
    (lambda ()
      (putenv "ProgramFiles" "")
      (putenv "ProgramFiles(x86)" "")
      (putenv "ProgramW6432" ""))
    (lambda ()
      (check-false (upd:install-dir-under-program-files?
                    "C:\\Program Files\\MoveBit")))
    (lambda ()
      (putenv "ProgramFiles" "")
      (putenv "ProgramFiles(x86)" "")
      (putenv "ProgramW6432" ""))))

(test-case "select-update splits the windows feed by install kind"
  ;; The feed carries both windows installables; the kind picks one.
  (define config
    (apply updater-config "site.jrtx.movebit" "0.0.1" 'stable
           'windows 'x64
           pub "movebit-test" 50 download-limit
           component-tail))
  (define manifest
    (update-manifest
     "site.jrtx.movebit" "9.9.9" 7 'stable
     "2026-10-10T00:00:00Z" "0.0.0" #f #t 100
     (list (apply update-artifact 'windows 'x64
                  "https://dl.example/movebit-9.9.9-windows-x64.zip"
                  payload-sha256 (file-size payload-zip) 'zip '()
                  component-tail)
           (apply update-artifact 'windows 'x64
                  "https://dl.example/movebit-9.9.9-windows-x64.msi"
                  payload-sha256 (file-size payload-zip) 'msi '()
                  component-tail))))
  (define msi (select-update config manifest #:install-kind 'msi))
  (check-equal?
   (update-artifact-installer (update-candidate-artifact msi)) 'msi)
  (define portable (select-update config manifest #:install-kind 'portable))
  (check-equal?
   (update-artifact-installer (update-candidate-artifact portable)) 'zip)
  ;; Unfiltered (Linux's posture) keeps matching the plain first entry.
  (check-true (update-candidate? (select-update config manifest))))

;; ---- windows apply helpers (pure script recipes) -----------------------------------

(test-case "the zip swap script backs up, rolls back, and marks failures"
  (define script (upd:zip-apply-script "C:\\Apps\\MoveBit" "C:\\stage" 4242))
  ;; wait for the exact PID, then move the old install aside FIRST
  (check-true (string-contains? script "PID eq 4242"))
  (check-true (string-contains? script "ren \"C:\\Apps\\MoveBit\" \"MoveBit.old\""))
  (check-true (string-contains? script "robocopy \"C:\\stage\" \"C:\\Apps\\MoveBit\""))
  ;; a failed copy restores the .old and relaunches the old exe — the
  ;; update never strands the user without a working install
  (check-true (string-contains? script ":rollback"))
  (check-true (string-contains? script "ren \"C:\\Apps\\MoveBit.old\" \"MoveBit\""))
  ;; a failed rename also relaunches the untouched old install
  (check-true (string-contains? script ":renamefail"))
  ;; both failure paths leave the marker the next launch surfaces once
  (check-equal? (length (regexp-match* #rx"update-failed\\.txt" script)) 2))

(test-case "the msi handoff script runs one passive msiexec upgrade"
  (define script
    (upd:msi-apply-script "C:\\Program Files\\MoveBit"
                          "C:\\data\\updates\\movebit-9.9.9-windows-x64.msi"
                          "C:\\data\\updates\\msiexec.log" 7))
  (check-true (string-contains?
               script "msiexec /passive /norestart /i \"C:\\data\\updates\\movebit-9.9.9-windows-x64.msi\""))
  ;; the log lands beside the helper; a failure relaunches the old install
  (check-true (string-contains? script "/l* \"C:\\data\\updates\\msiexec.log\""))
  (check-true (string-contains? script ":fail"))
  (check-true (string-contains? script "update-failed.txt"))
  (check-true (string-contains?
               script "start \"\" \"C:\\Program Files\\MoveBit\\RivetHost.exe\"")))

;; ---- cancel (the start gesture toggles) ---------------------------------------------

;; A server that dribbles the body a few KB at a time — slow enough that the
;; cancel gesture lands mid-flight, deterministic enough for CI.
(define (serve-dribble! total-bytes)
  (define listener (tcp-listen 0 16 #f "127.0.0.1"))
  (define-values (_bind-host port-number _peer-host _peer-port)
    (tcp-addresses listener #t))
  (define server
    (thread
     (lambda ()
       (let accept-loop ()
         (define-values (in out) (tcp-accept listener))
         (thread
          (lambda ()
            (define request-line (read-line in 'return-linefeed))
            (let drain ()
              (define line (read-line in 'return-linefeed))
              (unless (or (eof-object? line) (equal? line "") (equal? line "\r"))
                (drain)))
            (write-string
             (format "HTTP/1.0 200 OK\r\nContent-Length: ~a\r\n\r\n" total-bytes)
             out)
            (flush-output out)
            (define chunk (make-bytes 16384 9))
            (let send ([sent 0])
              (when (< sent total-bytes)
                (with-handlers ([exn:fail? void])  ; the cancel closed it
                  (write-bytes chunk out)
                  (flush-output out)
                  (sleep 0.02)
                  (send (+ sent (bytes-length chunk))))))
            (close-output-port out)
            (close-input-port in)))
         (accept-loop)))))
  (values port-number
          (lambda ()
            (kill-thread server)
            (tcp-close listener))))

(test-case "starting a download while one runs cancels it, phase returns to idle"
  ;; The cancel path needs a worker genuinely mid-download: a dribbling
  ;; server keeps the read loop busy while the toggle breaks it (~2 MB at
  ;; 16 KB / 20 ms is a few seconds — fast enough for CI, slow enough to
  ;; cancel mid-flight).
  (define total (* 2 1024 1024))
  (define payload-sha (bytes->hex-string (sha256-bytes (make-bytes total 9))))
  (define-values (port-number stop-server!) (serve-dribble! total))
  (define config
    (apply updater-config "site.jrtx.movebit" "0.1.0" 'stable
           (upd:platform-symbol) (upd:architecture-symbol)
           pub "movebit-test" 0 download-limit
           component-tail))
  (define candidate
    (select-update config
                   (update-manifest
                    "site.jrtx.movebit" "9.9.9" 7 'stable
                    "2026-10-10T00:00:00Z" "0.0.0" #f #t 100
                    (list (apply update-artifact
                                 (upd:platform-symbol) (upd:architecture-symbol)
                                 (format "http://127.0.0.1:~a/movebit-9.9.9.zip"
                                         port-number)
                                 payload-sha total
                                 'zip '()
                                 component-tail)))))
  (check-true (update-candidate? candidate))
  (parameterize ([upd:current-install-dir test-data-dir])
    (upd:reset-update-state!)
    (upd:set-candidate! candidate)
    (upd:start-download! test-data-dir)
    (sleep 0.3)  ; let the worker get mid-flight
    (check-equal? (hash-ref (upd:update-state-snapshot) 'phase) "downloading")
    ;; the toggle: a second start IS the cancel
    (upd:start-download! test-data-dir)
    (let loop ([deadline (+ (current-seconds) 10)])
      (define phase (hash-ref (upd:update-state-snapshot) 'phase))
      (cond
        [(equal? phase "idle") (void)]
        [(> (current-seconds) deadline)
         (fail "cancel never landed the phase on idle")]
        [else (sleep 0.05) (loop deadline)]))
    (check-false (hash-ref (upd:update-state-snapshot) 'downloadedPath #f))
    ;; the candidate survives the cancel — the update stays one click away
    (check-equal? (hash-ref (upd:update-state-snapshot) 'availableVersion)
                  "9.9.9")
    ;; and a fresh start after the cancel runs to completion
    (upd:start-download! test-data-dir)
    (define phase (wait-for-terminal-phase! 300))
    (check-equal? phase "downloaded"
                  (format "~s" (hash-ref (upd:update-state-snapshot) 'message))))
  (stop-server!))

;; ---- state box contract ----------------------------------------------------------

;; The hosts' poll loop relies on these exact keys (phase/percent/message/
;; availableVersion/downloadedPath) surviving every transition.
(test-case "reset returns the state box to idle"
  (upd:reset-update-state!)
  (define snapshot (upd:update-state-snapshot))
  (check-equal? (hash-ref snapshot 'phase) "idle")
  (check-equal? (hash-ref snapshot 'percent) 0)
  (check-false (hash-ref snapshot 'availableVersion))
  (check-false (hash-ref snapshot 'downloadedPath)))

(delete-file payload-zip)
