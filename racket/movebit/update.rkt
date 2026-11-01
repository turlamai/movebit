#lang racket/base

;; MoveBit update wiring over `rivet/distribution`, following the fulcrum
;; reference implementation.
;;
;; Trust model (inherited from Rivet): HTTPS protects transport but is not
;; the root of update trust. The channel manifest is Ed25519-signed and
;; verified against the public key embedded below before any version
;; decision. Key management lives in scripts/update-keys.sh: key generation,
;; the exact replacement of `current-update-public-key-hex`, and rotation via
;; the key id (ship a client trusting the next key before signing with it).
;;
;; The backend verifies and downloads the signed update artifact; the host
;; owns installation. A check fetches and verifies the signed channel
;; manifest; the artifact download runs on a background thread with progress
;; published to a state box that the UI polls through the `get-update-state`
;; RPC (RVT1 events are thread-local, so a background thread cannot emit
;; them directly). The feed serves portable archives per platform:
;;   Windows — per-user / portable installs: the zip IS the install layout,
;;     `prepare-install!` extracts the verified archive into a staging
;;     directory and writes a helper script that waits for the app to exit,
;;     moves the old install aside, swaps the payload (restoring the old
;;     install when the copy fails), and relaunches. MSI installs (Program
;;     Files) take the feed's signed .msi and hand off to msiexec instead.
;;   macOS — same shape as Windows: the zip carries movebit.app, the helper
;;     swaps the bundle with a backup + rollback rename and relaunches.
;;   Linux — AppImage installs update through the sibling .AppImage release
;;     asset (downloaded, sidecar-checked, swapped over the running image);
;;     tarball/package installs stay manual, so `prepare-install!` refuses
;;     and the host hands off the downloaded file or shows guidance.

(require net/url
         rivet/app-info
         rivet/distribution
         racket/file
         racket/format
         racket/list
         racket/path
         racket/port
         racket/random
         racket/string
         racket/system
         ffi/unsafe
         (only-in ffi/unsafe/define define-ffi-definer)
         "paths.rkt")

(provide current-update-version
         current-install-dir
         default-update-base-url
         update-key-id
         maximum-download-bytes
         hex->bytes
         effective-version
         movebit-update-configured?
         platform-symbol
         architecture-symbol
         install-kind
         install-dir-under-program-files?
         update-state-snapshot
         reset-update-state!
         perform-check!
         update-check-throttle-seconds
         update-check-throttled?
         record-update-check-stamp!
         rollout-bucket
         start-download!
         cancel-download!
         prepare-install!
         appimage-flavor?
         appimage-asset-name
         zip-apply-script
         msi-apply-script
         ;; test seams: drive the download paths against a local server
         ;; without a network check (the threadly test-suite shape)
         set-candidate!
         download-with-progress!
         download-appimage-with-progress!)

;; Ed25519 public key, DER SPKI hex-encoded — committed on purpose: the
;; public half only enables verification. Rotation replaces this hex and the
;; key id below (ship clients trusting the next key before signing with it).
;; raw 32 bytes (base64) t4Z+rtAk2NtcgFBUX+r139X1c2EnVOaI/HxkN4vs914= wrapped
;; in the standard SPKI header.
(define current-update-public-key-hex
  (string-append
   "302a300506032b6570032100"
   "b7867eaed024d8db5c8050545feaf5dfd5f573612754e688fc7c64378becf75e"))
(define update-key-id "movebit-2026-10")

(define default-update-base-url
  "https://github.com/turlamai/movebit/releases/latest/download")

(define maximum-download-bytes (* 512 1024 1024))

(define current-update-version (make-parameter "0.0.0"))
;; The application install directory (where RivetHost.exe lives). The host
;; hands it over; headless tests parameterize a temp directory.
(define current-install-dir (make-parameter (current-directory)))

;; ---------- public key ----------

(define (hex->bytes s)
  (let ([n (string-length s)])
    (if (and (even? n) (>= n 2))
        (apply bytes (for/list ([i (in-range 0 n 2)])
                       (string->number (substring s i (+ i 2)) 16)))
        #f)))

(define (movebit-update-configured?)
  (and current-update-public-key-hex
       (hex->bytes current-update-public-key-hex)
       #t))

;; The manifest verifier takes a parsed key object, not raw DER. Lazy on
;; purpose: FFI at module-import time kills embedded apps at startup (the
;; landmine rivet/distribution/crypto.rkt documents); a failure here
;; surfaces as an honest "update check failed" instead of a dead app.
(define (current-update-public-key)
  (bytes->ed25519-public-key (hex->bytes current-update-public-key-hex)))

;; ---------- platform identity ----------

(define (platform-symbol)
  (case (system-type 'os)
    [(macosx) 'macos]
    [(windows) 'windows]
    [else 'linux]))

(define (architecture-symbol)
  (case (system-type 'arch)
    [(aarch64 arm64) 'arm64]
    [else 'x64]))

;; The running version: the packaged app reads rivet-app-info.rktd. The
;; parameter exists for headless tests and for unpackaged dev runs where no
;; app-info file exists (the packaged version still comes from the file).
(define (effective-version)
  (define configured (current-update-version))
  (if (and (not (string=? configured "0.0.0")) configured)
      configured
      (with-handlers ([exn:fail? (lambda (_) configured)])
        (app-version))))

;; Rivet main grew a trailing `component` discriminator on updater-config
;; (and update-artifact): one feed may carry several installables per
;; platform, and the config names which entry this consumer selects.
;; MoveBit ships plain component-less artifacts (`release --update-payload`
;; without a component keeps #f), so select #f when the field exists. The
;; release pin (v0.11.0) predates the field — branch on the constructor
;; arity until the pin moves past it, then inline the argument.
(define component-tail
  (if (equal? (procedure-arity updater-config) 10) (list #f) '()))

;; Sticky rollout bucket, 0..99: a manifest rolling out to N matches only
;; buckets below N, so a bad build can be stopped from spreading while the
;; feed is fixed. Generated once per machine (crypto-random-bytes, NOT
;; racket/base's `random` — its fixed seed would put every fresh install in
;; the same lockstep bucket, the trap taskly's updater documents) and
;; persisted in bootstrap.json next to the per-machine throttle stamp.
(define (rollout-bucket)
  (define existing (hash-ref (load-bootstrap) 'rollout-bucket #f))
  (if (and (exact-integer? existing) (<= 0 existing 99))
      existing
      (let ([fresh (modulo (integer-bytes->integer (crypto-random-bytes 4) #t #t)
                           100)])
        (save-bootstrap (hash-set (load-bootstrap) 'rollout-bucket fresh))
        fresh)))

(define (updater-config* maximum-bytes)
  (apply updater-config
         "site.jrtx.movebit"
         (effective-version)
         'stable
         (platform-symbol)
         (architecture-symbol)
         (current-update-public-key)
         update-key-id
         ;; The persisted bucket: today the manifest rolls out to 100, so
         ;; every bucket matches; a partial rollout narrows the cohort
         ;; without any client change.
         (rollout-bucket)
         maximum-bytes
         component-tail))

;; ---------- install shape (which feed entry this install may apply) ----------
;;
;; select-update's install-kind picks between the feed's installables for
;; this platform. The MSI lands under Program Files (rivet's perMachine
;; scope), where the in-place zip swap has no write access — those installs
;; take the signed .msi artifact and hand off to msiexec (one UAC consent);
;; per-user / portable installs keep the automatic zip swap. macOS zips are
;; portable. Linux stays unfiltered: the feed entry is the tarball (the
;; AppImage swaps the sibling asset at download time; deb/rpm/tarball
;; installs get guidance, never a download). Same ProgramFiles* prefix
;; signal taskly's IsMsiInstall uses.

;; Pure over current-install-dir so tests can pin the decision.
(define (install-dir-under-program-files? install-string)
  (define install
    (string-downcase
     (regexp-replace #rx"[/\\]+$" install-string "")))
  (for/or ([variable (in-list '("ProgramFiles"
                                "ProgramFiles(x86)"
                                "ProgramW6432"))])
    (define value (getenv variable))
    (and value
         (not (string=? value ""))
         (let ([prefix (string-downcase
                        (regexp-replace #rx"[/\\]+$" value ""))])
           (and (not (string=? prefix ""))
                (or (string=? install prefix)
                    (string-prefix? install (string-append prefix "\\"))))))))

(define (install-kind)
  (case (platform-symbol)
    [(macos) 'portable]
    [(windows)
     (if (install-dir-under-program-files?
          (path->string (current-install-dir)))
         'msi
         'portable)]
    ;; Linux: unfiltered — the only linux artifact is the tarball.
    [else #f]))

;; ---------- shared update state (UI-visible) ----------

;; phase: idle | checking | downloading | downloaded | ready-to-apply | error
;; The key set is the hosts' poll contract (get-update-state reads it) —
;; every key is present in every state, #f when not applicable.
(define update-state
  (box (hasheq 'phase "idle"
               'percent 0
               'message #f
               'availableVersion #f
               'downloadedPath #f)))

(define candidate-box (box #f))
(define worker-thread-box (box #f))

(define (state-set! key value)
  (set-box! update-state (hash-set (unbox update-state) key value)))

(define (update-state-snapshot)
  (unbox update-state))

(define (reset-update-state!)
  (set-box! candidate-box #f)
  (set-box! update-state
            (hasheq 'phase "idle"
                    'percent 0
                    'message #f
                    'availableVersion #f
                    'downloadedPath #f)))

(define (set-update-error! message)
  (state-set! 'phase "error")
  (state-set! 'message message))

;; ---------- silent-check throttle (the family's 4-hour stamp) --------------
;;
;; The family contract (taskly's settings whitelist, threadly's local stamp
;; files): silent checks are throttled by a PERSISTENT per-machine stamp, so
;; a restart does not force a fresh check on a freshly checked install. The
;; stamp lives in bootstrap.json — per-machine by design; a stamp inside the
;; synced data dir would let one device's check suppress another's. Only a
;; SETTLED check refreshes it: a definitive answer (available / up-to-date)
;; or a deterministic failure (developer build, no feed URL). Transient
;; failures — network errors, unreadable feeds — leave the stamp alone so
;; the next launch retries. Manual checks never consult the throttle, and a
;; settled manual check refreshes the stamp like any other settled check.

(define update-check-throttle-seconds (* 4 60 60))

(define (record-update-check-stamp!)
  (save-bootstrap
   (hash-set (load-bootstrap) 'last-update-check (current-seconds))))

;; A failed read counts as "never checked" — the throttle must never block
;; on a corrupt stamp.
(define (update-check-throttled?)
  (define stamp (hash-ref (load-bootstrap) 'last-update-check #f))
  (and (exact-integer? stamp)
       (< (- (current-seconds) stamp) update-check-throttle-seconds)))

;; ---------- check ----------

;; A check is settled when it produced a definitive answer or hit a
;; deterministic failure (the developer-build / no-feed-URL refusals) —
;; exactly the results that may refresh the persistent throttle stamp.
;; Transient failures (network, feed fetch/verification) are not settled.
(define (perform-check! base-url)
  (define (settle result)
    (when (hash-ref result 'settled #f)
      (record-update-check-stamp!))
    result)
  (reset-update-state!)
  (state-set! 'phase "checking")
  (with-handlers
      ([exn:fail?
        (lambda (e)
          (state-set! 'phase "error")
          (state-set! 'message (exn-message e))
          (settle (hasheq 'status "error" 'settled #f
                          'message (exn-message e))))])
    (cond
      [(not (movebit-update-configured?))
       (state-set! 'phase "idle")
       (settle
        (hasheq 'status "error" 'settled #t
                'message "updates unavailable: developer build (no update key configured)"))]
      [(or (not base-url) (string=? (string-trim base-url) ""))
       (state-set! 'phase "idle")
       (settle
        (hasheq 'status "error" 'settled #t
                'message "updates unavailable: no update base URL configured"))]
      [else
       (define manifest
         (fetch-update-manifest
          (string-append (regexp-replace* #rx"/+$" base-url "") "/update-manifest.json")
          (current-update-public-key)
          #:key-id update-key-id
          #:maximum-bytes (* 4 1024 1024)))
       (define candidate
         (select-update (updater-config* (* 4 1024 1024)) manifest
                        #:install-kind (install-kind)))
       (cond
         [candidate
          (set-box! candidate-box candidate)
          (define inner (update-candidate-manifest candidate))
          (state-set! 'phase "idle")
          (state-set! 'availableVersion (update-manifest-version inner))
          (settle
           (hasheq 'status "available" 'settled #t
                   'currentVersion (effective-version)
                   'availableVersion (update-manifest-version inner)
                   'build (update-manifest-build inner)
                   'publishedAt (update-manifest-published-at inner)
                   'sizeBytes (update-artifact-size
                               (update-candidate-artifact candidate))))]
         [else
          (state-set! 'phase "idle")
          (state-set! 'availableVersion (void))
          (settle
           (hasheq 'status "up-to-date" 'settled #t
                   'currentVersion (effective-version)))])])))

;; Test seam: install a candidate without a network check so the download
;; paths can be driven against a local HTTP server.
(define (set-candidate! candidate) (set-box! candidate-box candidate))

;; ---------- download ----------

(define (artifact-file-name candidate)
  (define raw (update-artifact-url (update-candidate-artifact candidate)))
  (or (and (string? raw)
           (with-handlers ([exn:fail? (lambda (_) #f)])
             (let loop ([segments (url-path (string->url raw))] [seen #f])
               (cond
                 [(null? segments) seen]
                 [else
                  (define raw-seg (path/param-path (car segments)))
                  (loop (cdr segments)
                        (if (and (string? raw-seg) (not (string=? raw-seg "")))
                            raw-seg
                            seen))]))))
      "movebit-update"))

;; Download watchdog bounds. rivet's download-update waits on
;; read-bytes-avail! with no timeout, so a connection that stalls without
;; RST/FIN parks the worker thread forever — the UI would rest on
;; "downloading" with no terminal state. Two finite bounds keep the phase
;; machine honest: no byte progress for the stall limit, or wall clock past
;; the total limit, breaks the worker (rivet's partial-file cleanup runs,
;; and the worker reports phase=error itself) so the UI always gets a
;; terminal state.
(define download-stall-limit-seconds 120)
(define download-total-limit-seconds (* 30 60))
(define last-progress-seconds (box 0))

;; rivet's download-update owns the whole artifact path — redirect-following
;; fetch, signed-size cap, .partial cleanup on any failure, SHA-256 + size
;; verification against the signed manifest, atomic rename — so the wrapper
;; only maps its byte progress onto the integer percent the UI polls, and
;; feeds the watchdog's stall clock on every report.
(define (download-with-progress! candidate destination)
  (define total (update-artifact-size (update-candidate-artifact candidate)))
  (download-update
   (updater-config* maximum-download-bytes)
   candidate destination
   #:on-progress
   (lambda (done)
     (set-box! last-progress-seconds (current-seconds))
     (state-set! 'percent
                 (if (> total 0)
                     (min 100 (quotient (* done 100) total))
                     0)))))

(define (updates-dir data-dir)
  (build-path data-dir "updates"))

;; ---------- AppImage flavor (Linux installs run from an AppImage) ----------
;;
;; The feed's linux entry is the tar.gz; AppImage installs update through the
;; sibling .AppImage release asset: same asset base with .tar.gz → .AppImage
;; (movebit publishes AppImages under the release-contract arch spelling,
;; x64|arm64 — identical to the feed entry, so the derivation is only the
;; extension swap), checksummed against the published .AppImage.sha256
;; sidecar. The Ed25519 manifest still authenticates the tar.gz entry that
;; carried the version; the sidecar is a plain checksum over the same HTTPS
;; origin. The download lands NEXT TO the running image (same filesystem →
;; atomic rename) and replaces it after the sidecar verifies; the host
;; re-execs the replaced image on user consent.

;; $APPIMAGE (set by the AppImage runtime) is inherited by the embedded
;; backend — its presence IS the install shape; no config plumbing needed.
;; platform-symbol is the stable predicate: system-type's os is 'unix on
;; Linux, so an (eq? (system-type 'os) 'linux) guard is never true there
;; (the same trap the threadly suite documents).
(define (appimage-flavor?)
  (and (eq? (platform-symbol) 'linux)
       (let ([self (getenv "APPIMAGE")])
         (and self (not (string=? self ""))))))

;; Pure so tests can pin the derivation.
(define (appimage-asset-name tar-gz-filename)
  (unless (string-suffix? tar-gz-filename ".tar.gz")
    (error 'appimage-asset-name "not a tar.gz filename: ~a" tar-gz-filename))
  (string-append (substring tar-gz-filename 0
                            (- (string-length tar-gz-filename) 7))
                 ".AppImage"))

(define (appimage-artifact-urls candidate)
  (define url (update-artifact-url (update-candidate-artifact candidate)))
  (define filename
    (last (string-split (car (string-split url "?")) "/")))
  (define appimage-name (appimage-asset-name filename))
  (values (string-replace url filename appimage-name)
          (string-append (string-replace url filename appimage-name)
                         ".sha256")))

(define (appimage-download-target)
  ;; Stage the download next to the running image so the final rename stays
  ;; on one device (atomic).
  (define self (getenv "APPIMAGE"))
  (unless (and self (non-empty-string? self))
    (error 'start-download "APPIMAGE is not set; not running as an AppImage"))
  (values self
          (make-temporary-file "movebit-update-~a.AppImage" #f (path-only self))))

;; sha256sum format: "<hex>  <filename>"; the first token is the digest.
(define (fetch-sidecar-sha256! url)
  (define in (get-pure-port (string->url url)
                            '("User-Agent: MoveBit-Updater/1")
                            #:redirections 10))
  (dynamic-wind
    void
    (lambda ()
      (define digest
        (let ([body (string-trim (port->string in))])
          (if (string=? body "") "" (first (string-split body)))))
      (unless (regexp-match? #px"^[0-9a-fA-F]{64}$" digest)
        (error 'start-download "checksum sidecar has an unexpected shape"))
      (string-downcase digest))
    (lambda () (close-input-port in))))

;; Sibling-asset downloads come without a signed manifest, so the response
;; head is the only total available: parse Content-Length for the progress
;; percent (0 → indeterminate), then hand the body port to the copy loop.
;; Connection: close keeps the copy ending at EOF, like the manifest-verified
;; flow.
(define (open-download-with-total! url)
  (define in (get-impure-port (string->url url)
                              '("User-Agent: MoveBit-Updater/1"
                                "Connection: close")))
  (let loop ([total 0])
    (define line (read-line in 'return-linefeed))
    (cond
      [(eof-object? line) (values in 0)]
      [(non-empty-string? (string-trim line))
       (define match
         (regexp-match #px"(?i:^content-length:\\s*(\\d+))" line))
       (loop (if match (string->number (second match)) total))]
      [else (values in total)])))

;; Copy with progress; feeds the watchdog's stall clock on every read (not
;; just integer percent changes, so a slow link never false-trips it).
(define (copy-with-progress! in out total)
  (define buffer (make-bytes 65536))
  (let loop ([done 0] [last-percent -1])
    (define count (read-bytes-avail! buffer in))
    (cond
      [(eof-object? count) done]
      [else
       (set-box! last-progress-seconds (current-seconds))
       (write-bytes buffer out 0 count)
       (define next (+ done count))
       (define percent
         (if (> total 0)
             (min 100 (quotient (* next 100) total))
             0))
       (when (> percent last-percent)
         (state-set! 'percent percent))
       (loop next percent)])))

(define (download-appimage-with-progress! candidate)
  (define-values (appimage-url sidecar-url)
    (appimage-artifact-urls candidate))
  (define-values (self temporary) (appimage-download-target))
  (define expected (fetch-sidecar-sha256! sidecar-url))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (when (file-exists? temporary)
                       (delete-file temporary))
                     (raise e))])
    (define-values (in total) (open-download-with-total! appimage-url))
    (dynamic-wind
      void
      (lambda ()
        (call-with-output-file temporary
          #:exists 'truncate/replace
          #:mode 'binary
          (lambda (out) (copy-with-progress! in out total))))
      (lambda () (close-input-port in)))
    (define actual (string-downcase (sha256-file/hex temporary)))
    (unless (string=? actual expected)
      (raise-arguments-error 'start-download
                             "downloaded appimage does not match its checksum sidecar"
                             "expected" expected
                             "actual" actual))
    ;; The replaced image must stay executable: rename carries the temp
    ;; file's modes, so set them explicitly before the swap. The setter
    ;; only takes integer bits — the vector form is a contract violation
    ;; on every platform (the same trap taskly 63c1f00 fixed), so the
    ;; AppImage swap must set modes the portable way.
    (file-or-directory-permissions temporary #o755)
    (rename-file-or-directory temporary self #t)
    self))

;; A cancelled download is not a failure: the broken worker lands the phase
;; back on idle with the candidate intact, so the UI returns to the
;; available state and another start is one click away.
(define cancel-requested-box (box #f))

(define (download-running?)
  (define worker (unbox worker-thread-box))
  (and worker (thread-running? worker)))

(define (cancel-download!)
  (when (download-running?)
    (set-box! cancel-requested-box #t)
    (break-thread (unbox worker-thread-box)))
  (void))

;; Runs on a backend worker thread; the host follows progress via the
;; update-state RPC. Never raises: failures surface through the phase.
;; Doubles as the cancel gesture (the taskly toggle contract): the start
;; gesture while a download runs IS the cancel — no second RPC, the schema
;; stays put and every host's Cancel button just calls this again.
(define (start-download! data-dir)
  (cond
    [(download-running?)
     (cancel-download!)]
    [else
     (define candidate (unbox candidate-box))
     (unless candidate
       (error 'start-download! "no update is available; run a check first"))
     (set-box! cancel-requested-box #f)
     (state-set! 'phase "downloading")
     (state-set! 'percent 0)
     (state-set! 'message (void))
     (state-set! 'availableVersion
                 (update-manifest-version (update-candidate-manifest candidate)))
     (define destination
       (build-path (updates-dir data-dir) (artifact-file-name candidate)))
     (set-box! last-progress-seconds (current-seconds))
     (define worker-thread
       (thread
        (lambda ()
          ;; The watchdog breaks a stalled worker and the cancel gesture
          ;; breaks an in-flight one; exn:break is not an exn:fail, so each
          ;; needs its own arm — either way rivet's partial cleanup removes
          ;; the .partial and the phase lands on a terminal state (never
          ;; mid-flight).
          (with-handlers
              ([(lambda (e) (or (exn:fail? e) (exn:break? e)))
                (lambda (e)
                  (cond
                    [(unbox cancel-requested-box)
                     (set-box! cancel-requested-box #f)
                     (state-set! 'phase "idle")
                     (state-set! 'percent 0)
                     (state-set! 'message #f)
                     (state-set! 'downloadedPath #f)]
                    [(exn:break? e)
                     (state-set! 'phase "error")
                     (state-set! 'message "update download stalled or timed out")]
                    [else
                     (state-set! 'phase "error")
                     (state-set! 'message (exn-message e))]))])
            (define path
              (if (appimage-flavor?)
                  ;; AppImage: the sibling asset is sidecar-checked and swapped
                  ;; over the running image in place; downloadedPath IS the
                  ;; image path.
                  (download-appimage-with-progress! candidate)
                  (download-with-progress! candidate destination)))
            (state-set! 'phase "downloaded")
            (state-set! 'percent 100)
            (state-set! 'availableVersion
                        (update-manifest-version
                         (update-candidate-manifest candidate)))
            (state-set! 'downloadedPath (path->string path))))))
     (set-box! worker-thread-box worker-thread)
     ;; Watchdog: exits once the worker finishes on its own; otherwise a stall
     ;; (no byte progress) or the total wall-clock limit breaks the worker so
     ;; phase never rests on "downloading" indefinitely.
     (define download-started (current-seconds))
     (thread
      (lambda ()
        (let loop ()
          (cond
            [(sync/timeout download-stall-limit-seconds
                           (thread-dead-evt worker-thread))
             (void)]
            [(> (- (current-seconds) (unbox last-progress-seconds))
                download-stall-limit-seconds)
             (break-thread worker-thread)]
            [(> (- (current-seconds) download-started)
                download-total-limit-seconds)
             (break-thread worker-thread)]
            [else (loop)]))))])
  (void))

;; ---------- install preparation (Windows / macOS) ----------
;;
;; The verified archive is staged and an apply-helper script is written; the
;; host exits and the detached helper finishes the swap:
;;   Windows — per-user / portable installs: the zip IS the install layout.
;;     Extract into <data-dir>/updates/staged/ and write apply-update.cmd:
;;     the helper waits for the running app to exit, moves the install
;;     directory aside, robocopys the staged payload over a fresh install
;;     directory (restoring the old one when the copy fails), relaunches,
;;     and removes itself. MSI installs (Program Files) skip all of that:
;;     the helper runs one passive msiexec upgrade instead — msiexec
;;     elevates, so the unwritable install directory is not an obstacle.
;;   macOS — the zip carries movebit.app. Extract the same way (bsdtar reads
;;     zip on macOS too), then apply-update.sh copies the staged bundle onto
;;     the install volume and swaps it with a backup + rollback rename
;;     before relaunching via `open`.
;;   Linux — install is never automated here: AppImage swaps happened at
;;     download time, tarball/package installs stay manual (the host shows
;;     the downloaded file or the package-manager guidance), so
;;     `prepare-install!` refuses honestly.

(define (staged-dir data-dir)
  (build-path (updates-dir data-dir) "staged"))

;; A staged macOS bundle counts only when the executable layout is real.
;; Contents/MacOS is a directory, so the check is directory-exists? —
;; file-exists? is #f on directories and would refuse every real bundle
;; (found by the update-flow test port; prepare-install! never got past
;; the completeness gate on macOS).
(define (mac-bundle? path)
  (and (directory-exists? path)
       (string-suffix? (path->string (file-name-from-path path)) ".app")
       (directory-exists? (build-path path "Contents" "MacOS"))))

;; The layout a staged payload must have before the helper may touch the
;; install directory.
(define (staged-payload-complete? staged)
  (case (system-type 'os)
    [(macosx)
     (for/or ([entry (in-list (directory-list staged #:build? #t))])
       (mac-bundle? entry))]
    [else
     (file-exists? (build-path staged "RivetHost.exe"))]))

(define (extract-zip! zip-path destination)
  (make-directory* destination)
  ;; Windows ships bsdtar since 1803 and macOS /usr/bin/tar IS bsdtar — both
  ;; read zip, and it is an order of magnitude faster than Expand-Archive,
  ;; whose per-file copy grinds against real-time antivirus for minutes on a
  ;; 300-file payload. The child's output goes to a log FILE: a GUI process
  ;; has no console, and a subprocess inheriting the embedded runtime's dead
  ;; stdout handle blocks forever.
  (define log (path-add-extension destination #".extract.log"))
  (call-with-output-file log
    (lambda (out)
      (parameterize ([current-output-port out]
                     [current-error-port out])
        (unless (system*
                 (find-executable-path "tar")
                 "-xf" (path->string zip-path)
                 "-C" (path->string destination))
          (error 'extract-zip!
                 "tar extraction failed; see ~a" log))))
    #:exists 'replace)
  (unless (staged-payload-complete? destination)
    (error 'prepare-install!
           "staged payload is incomplete (no update payload)")))

;; The install directory's base name — `ren` takes the NEW name as a bare
;; token, never a path. Split on BOTH separators by hand: the script text is
;; generated on every platform (tests included), and simple-form-path's
;; separators are the generating platform's — on unix a Windows path stays
;; one element and the rename would lose the .old suffix.
(define (install-base-name install-string)
  (define trimmed (regexp-replace #rx"[/\\]+$" install-string ""))
  (last (regexp-split #rx"[/\\]" trimmed)))

;; Pure so tests on every platform can pin the swap recipe. Safety shape
;; (the taskly handoff): move the old install aside FIRST, robocopy the
;; staged payload into the fresh directory, roll the rename back when the
;; copy fails — the old version survives every failure path and the batch
;; relaunches it. The update-failed.txt marker tells the next launch to
;; surface the failure once. `cd /d` first: the helper inherits the app's
;; working directory, and a cmd whose cwd sits inside a directory being
;; renamed would hold it open.
(define (zip-apply-script install staged pid)
  (define old (string-append install ".old"))
  (string-append
   "@echo off\r\n"
   "set TRACE=%~dp0apply-update-trace.txt\r\n"
   "cd /d \"%~dp0\"\r\n"
   "echo [%date% %time%] helper started, waiting for PID "
   (number->string pid) " > \"%TRACE%\"\r\n"
   ":waitloop\r\n"
   "tasklist /FI \"PID eq " (number->string pid) "\" | find \""
   (number->string pid) "\" >nul\r\n"
   "if not errorlevel 1 (\r\n"
   "  timeout /t 1 /nobreak >nul\r\n"
   "  goto waitloop\r\n"
   ")\r\n"
   "echo [%time%] app exited, backing up the old install >> \"%TRACE%\"\r\n"
   "ren \"" install "\" \"" (install-base-name install) ".old\"\r\n"
   "if errorlevel 1 goto :renamefail\r\n"
   "echo [%time%] swapping payload >> \"%TRACE%\"\r\n"
   "robocopy \"" staged "\" \"" install "\" /E /NFL /NDL /NJH /NJS >> \"%TRACE%\" 2>&1\r\n"
   "echo [%time%] robocopy exit %errorlevel% >> \"%TRACE%\"\r\n"
   "if errorlevel 8 goto :rollback\r\n"
   "start \"\" \"" install "\\RivetHost.exe\"\r\n"
   "echo [%time%] relaunched, retiring backup >> \"%TRACE%\"\r\n"
   ;; A lingering .old (a file briefly held by antivirus) must not fail the
   ;; update that already succeeded — best effort only.
   "rmdir /s /q \"" old "\" >nul 2>&1\r\n"
   "del \"%~f0\"\r\n"
   "exit /b 0\r\n"
   ":rollback\r\n"
   "echo [%time%] FAILED swap, restoring the old install >> \"%TRACE%\"\r\n"
   "rmdir /s /q \"" install "\" >nul 2>&1\r\n"
   "ren \"" old "\" \"" (install-base-name install) "\"\r\n"
   "> \"%~dp0update-failed.txt\" echo robocopy failed (%errorlevel%)\r\n"
   "start \"\" \"" install "\\RivetHost.exe\"\r\n"
   "exit /b 1\r\n"
   ":renamefail\r\n"
   "echo [%time%] FAILED backup rename >> \"%TRACE%\"\r\n"
   "> \"%~dp0update-failed.txt\" echo backup rename failed\r\n"
   "start \"\" \"" install "\\RivetHost.exe\"\r\n"
   "exit /b 1\r\n"))

(define (write-apply-helper! data-dir pid)
  (define staged (staged-dir data-dir))
  ;; A trailing separator inside the quoted path reads as an escaped quote
  ;; in cmd (\"), mangling every argument after it — strip it.
  (define install
    (regexp-replace #rx"[/\\]+$" (path->string (current-install-dir)) ""))
  (define helper
    (build-path (updates-dir data-dir) "apply-update.cmd"))
  (call-with-output-file helper
    (lambda (out) (display (zip-apply-script install (path->string staged) pid) out))
    #:exists 'replace)
  helper)

;; Pure: the MSI handoff (the taskly shape). MSI installs upgrade in place:
;; wait for this process to exit, then one passive msiexec run — per-machine
;; installs surface a single UAC consent (unavoidable under /passive). A
;; failure keeps the old install working: the batch relaunches it and leaves
;; the failure marker for the next launch to surface once.
(define (msi-apply-script install msi-path log-path pid)
  (string-append
   "@echo off\r\n"
   "set TRACE=%~dp0apply-update-trace.txt\r\n"
   "cd /d \"%~dp0\"\r\n"
   "echo [%date% %time%] msi helper started, waiting for PID "
   (number->string pid) " > \"%TRACE%\"\r\n"
   ":waitloop\r\n"
   "tasklist /FI \"PID eq " (number->string pid) "\" | find \""
   (number->string pid) "\" >nul\r\n"
   "if not errorlevel 1 (\r\n"
   "  timeout /t 1 /nobreak >nul\r\n"
   "  goto waitloop\r\n"
   ")\r\n"
   "echo [%time%] app exited, running msiexec >> \"%TRACE%\"\r\n"
   "msiexec /passive /norestart /i \"" msi-path "\" /l* \"" log-path "\"\r\n"
   "echo [%time%] msiexec exit %errorlevel% >> \"%TRACE%\"\r\n"
   "if errorlevel 1 goto :fail\r\n"
   "start \"\" \"" install "\\RivetHost.exe\"\r\n"
   "echo [%time%] relaunched >> \"%TRACE%\"\r\n"
   "del \"%~f0\"\r\n"
   "exit /b 0\r\n"
   ":fail\r\n"
   "> \"%~dp0update-failed.txt\" echo msiexec failed (%errorlevel%)\r\n"
   "start \"\" \"" install "\\RivetHost.exe\"\r\n"
   "exit /b 1\r\n"))

(define (write-apply-helper-msi! data-dir pid)
  (define downloaded
    (hash-ref (update-state-snapshot) 'downloadedPath #f))
  (define install
    (regexp-replace #rx"[/\\]+$" (path->string (current-install-dir)) ""))
  (define updates (updates-dir data-dir))
  (define helper (build-path updates "apply-update.cmd"))
  (define script
    (msi-apply-script install
                      (path->string (string->path downloaded))
                      (path->string (build-path updates "msiexec.log"))
                      pid))
  (call-with-output-file helper
    (lambda (out) (display script out))
    #:exists 'replace)
  helper)

;; The staged bundle the helper will promote (extract-zip! already proved
;; one exists).
(define (staged-mac-bundle staged)
  (for/or ([entry (in-list (directory-list staged #:build? #t))])
    (and (mac-bundle? entry) entry)))

;; macOS apply helper: copy the staged bundle onto the install volume first
;; (the data dir may live on another volume), then swap with same-directory
;; renames — old bundle aside, promote the stage, roll back when the promote
;; fails — and relaunch via `open`. Written before the app exits so the only
;; work after quit is the swap.
(define (write-apply-helper-mac! data-dir pid)
  (define staged (staged-dir data-dir))
  (define bundle (staged-mac-bundle staged))
  (define install
    (regexp-replace #rx"[/\\]+$" (path->string (current-install-dir)) ""))
  (define helper
    (build-path (updates-dir data-dir) "apply-update.sh"))
  (define script
    (string-append
     "#!/bin/sh\n"
     "# MoveBit apply-update helper — written by the backend, spawned\n"
     "# detached. Waits for the app to exit, swaps the bundle, relaunches.\n"
     "PID=\"" (number->string pid) "\"\n"
     "INSTALL=\"" install "\"\n"
     "STAGED_BUNDLE=\"" (path->string bundle) "\"\n"
     "APP=\"$INSTALL/" (path->string (file-name-from-path bundle)) "\"\n"
     "BACKUP=\"$APP.old\"\n"
     "STAGE=\"$INSTALL/.movebit-update.app\"\n"
     "while kill -0 \"$PID\" 2>/dev/null; do sleep 1; done\n"
     "rm -rf \"$STAGE\"\n"
     "cp -R \"$STAGED_BUNDLE\" \"$STAGE\" || exit 1\n"
     "rm -rf \"$BACKUP\"\n"
     "[ -d \"$APP\" ] && mv \"$APP\" \"$BACKUP\"\n"
     "if mv \"$STAGE\" \"$APP\"; then\n"
     "  rm -rf \"$BACKUP\"\n"
     "  open \"$APP\"\n"
     "else\n"
     "  [ -d \"$BACKUP\" ] && mv \"$BACKUP\" \"$APP\"\n"
     "  exit 1\n"
     "fi\n"))
  (call-with-output-file helper
    (lambda (out) (display script out))
    #:exists 'replace)
  helper)

;; Verify the install directory is writable BEFORE the app exits — a pointer
;; to an unwritable directory would only fail inside the helper.
(define (assert-install-writable!)
  (define probe
    (build-path (current-install-dir) ".movebit-write-probe"))
  (call-with-output-file probe
    (lambda (out) (display "ok" out))
    #:exists 'replace)
  (delete-file probe))

;; Called from the prepare-update-install RPC on its worker: extract the
;; verified zip, write the helper, and hand back the command to spawn. The
;; host then exits and the detached helper finishes the swap.
(define (prepare-install! data-dir)
  ;; platform-symbol, not system-type's os — on Linux that is 'unix and the
  ;; refusal below never matched, so Linux installs fell into the
  ;; Windows/macOS flow (found by the swap-chain test on CI).
  (case (platform-symbol)
    [(linux)
     ;; AppImage swaps happen at download time; tarball/package installs are
     ;; manual (the host shows the file or the guidance). Never pretend.
     (error 'prepare-install! "install is not automated on this platform")]
    [else
     (define downloaded
       (hash-ref (update-state-snapshot) 'downloadedPath #f))
     (unless (and downloaded (file-exists? downloaded))
       (error 'prepare-install! "no downloaded update; run a download first"))
     (cond
       [(eq? (install-kind) 'msi)
        ;; The MSI shape is DEFINED by an install directory we cannot
        ;; write: no staging, no writability probe — msiexec elevates
        ;; itself, and the verified .msi downloads straight from the feed.
        (define helper (write-apply-helper-msi! data-dir (getpid)))
        (state-set! 'phase "ready-to-apply")
        (path->string helper)]
       [else
        (assert-install-writable!)
        (define staged (staged-dir data-dir))
        (when (directory-exists? staged)
          (delete-directory/files staged))
        (extract-zip! (string->path downloaded) staged)
        (define helper
          (if (eq? (platform-symbol) 'macos)
              (write-apply-helper-mac! data-dir (getpid))
              (write-apply-helper! data-dir (getpid))))
        (state-set! 'phase "ready-to-apply")
        (path->string helper)])]))

;; The apply helper waits on the precise PID of the exiting app, so a stray
;; RivetHost.exe from another install can never hold the swap open. The
;; embedded runtime shares the host's process, so this IS the host's pid.
(define getpid
  (case (system-type 'os)
    [(windows)
     (define-ffi-definer define-kernel32 (ffi-lib "kernel32"))
     (define-kernel32 GetCurrentProcessId (_fun -> _uint32))
     (lambda () (GetCurrentProcessId))]
    [(macosx)
     ;; libSystem is the macOS libc.
     (define-ffi-definer define-libsystem (ffi-lib "libSystem.B.dylib"))
     (define-libsystem getpid (_fun -> _int))
     (lambda () (getpid))]
    [else
     ;; Install preparation is not automated here (the host owns the three
     ;; install shapes); no helper is ever written.
     (lambda () 0)]))
