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
;;   Linux — AppImage installs select a first-class Ed25519-signed .AppImage
;;     artifact (size + digest verified before atomic replacement);
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
         appimage-download-target
         install-appimage!
         zip-apply-script
         msi-apply-script)

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

;; ---------- install shape (which feed entry this install may apply) ----------
;;
;; select-update's install-kind picks between the feed's installables for
;; this platform. The MSI lands under Program Files (rivet's perMachine
;; scope), where the in-place zip swap has no write access — those installs
;; take the signed .msi artifact and hand off to msiexec (one UAC consent);
;; per-user / portable installs keep the automatic zip swap. macOS zips are
;; portable. Linux AppImage installs select the signed 'appimage artifact;
;; deb/rpm/tarball installs stay manual. Same ProgramFiles* prefix
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
    ;; AppImage MUST select its own signed artifact, never a tar.gz sibling.
    [else (if (appimage-flavor?) 'appimage #f)]))

;; ---------- shared update state (UI-visible) ----------

;; phase: idle | checking | downloading | downloaded | ready-to-apply | error
;; The key set is the hosts' poll contract (get-update-state reads it) —
;; every key is present in every state, #f when not applicable.
(define (idle-snapshot)
  (hasheq 'phase "idle"
          'percent 0
          'message #f
          'availableVersion #f
          'downloadedPath #f))

(define update-state (box (idle-snapshot)))
(define updater-box (box #f))
(define download-root-box (box #f))
;; prepare-install! promotes a verified download to "ready-to-apply"; the
;; managed state has no such phase, so the product layers it on the
;; downloaded snapshot until the next check/download clears it.
(define phase-override-box (box #f))

(define (state-set! key value)
  (set-box! update-state (hash-set (unbox update-state) key value)))

;; The managed phases include transport/selection outcomes the UI treats as
;; idle: `available` carries its signal in availableVersion, `up-to-date`
;; means there is nothing to do, and `cancelled` returns the controls to
;; idle. Anything else passes through unchanged.
(define (managed-state->product state)
  (define phase (hash-ref state 'phase "idle"))
  (define mapped-phase
    (case phase
      [("available" "up-to-date" "cancelled") "idle"]
      [else phase]))
  (define idle? (string=? mapped-phase "idle"))
  (hasheq 'phase mapped-phase
          'percent (if idle? 0 (hash-ref state 'percent 0))
          'message (let ([message (and (not idle?)
                                       (hash-ref state 'message #f))])
                     (if message message #f))
          'availableVersion (let ([version (hash-ref state 'availableVersion #f)])
                              (if version version #f))
          'downloadedPath (let ([path (hash-ref state 'downloadedPath #f)])
                            (if path path #f))))

(define (update-state-snapshot)
  (define instance (unbox updater-box))
  (define base
    (if instance
        (managed-state->product (updater-state instance))
        (unbox update-state)))
  (define override (unbox phase-override-box))
  (if (and override (equal? (hash-ref base 'phase "idle") "downloaded"))
      (hash-set base 'phase override)
      base))

(define (reset-update-state!)
  ;; Dropping an instance while its worker runs would orphan the download;
  ;; land it on the terminal cancelled phase first.
  (define instance (unbox updater-box))
  (when (and instance (equal? (hash-ref (updater-state instance) 'phase)
                              "downloading"))
    (updater-cancel! instance)
    (updater-wait instance 5.0))
  (set-box! updater-box #f)
  (set-box! download-root-box #f)
  (set-box! phase-override-box #f)
  (set-box! update-state (idle-snapshot)))

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
  (cond
    ;; Keep the running transfer (and its instance) instead of orphaning
    ;; the worker; the UI retries the check once the download ends.
    [(download-running?)
     (settle (hasheq 'status "error" 'settled #f
                     'message "an update download is already running"))]
    [else
     (reset-update-state!)
     (cond
       [(not (movebit-update-configured?))
        (settle
         (hasheq 'status "error" 'settled #t
                 'message "updates unavailable: developer build (no update key configured)"))]
       [(or (not base-url) (string=? (string-trim base-url) ""))
        (settle
         (hasheq 'status "error" 'settled #t
                 'message "updates unavailable: no update base URL configured"))]
       [else
        (with-handlers
            ([exn:fail?
              (lambda (e)
                (state-set! 'phase "error")
                (state-set! 'message (exn-message e))
                (settle (hasheq 'status "error" 'settled #f
                                'message (exn-message e))))])
          (define instance (make-movebit-updater base-url))
          (set-box! updater-box instance)
          (define result (updater-check! instance))
          (settle (hash-set result 'settled
                            (not (equal? (hash-ref result 'status #f) "error")))))])]))

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

;; ---------- managed updater ----------

(define (manifest-url base-url)
  (string-append (regexp-replace* #rx"/+$" base-url "")
                 "/update-manifest.json"))

;; The verified image installs in place: chmod, keep the previous runnable
;; image as .previous, and atomically rename over the running file. Any
;; failure before the final rename leaves the original untouched.
(define (install-appimage! verified self)
  (define backup-temp
    (make-temporary-file "movebit-backup-~a.AppImage" #f (path-only self)))
  (define backup (string-append self ".previous"))
  (with-handlers ([exn?
                   (lambda (e)
                     (when (file-exists? backup-temp) (delete-file backup-temp))
                     (raise e))])
    (file-or-directory-permissions verified #o755)
    ;; Copy into a unique sibling and rename atomically: never follow a
    ;; pre-existing backup symlink or truncate a known-good backup in place.
    (copy-file self backup-temp #t)
    (file-or-directory-permissions backup-temp #o755)
    (rename-file-or-directory backup-temp backup #t)
    ;; Keep .previous after success for manual recovery if startup fails.
    (rename-file-or-directory verified self #t)
    self))

(define (make-movebit-updater base-url)
  ;; Set by the destination callback for an AppImage install and consumed
  ;; by the after-download hook in the same instance.
  (define appimage-self-box (box #f))
  (make-updater
   #:application-id "site.jrtx.movebit"
   #:current-version (effective-version)
   #:channel 'stable
   #:platform (platform-symbol)
   #:architecture (architecture-symbol)
   #:install-kind (install-kind)
   ;; MoveBit ships plain component-less artifacts (`release
   ;; --update-payload` without a component keeps #f).
   #:component #f
   ;; DER bytes: decoded lazily during the check, so a bad key surfaces as
   ;; an honest "update check failed" instead of killing module load.
   #:public-key (hex->bytes current-update-public-key-hex)
   #:key-id update-key-id
   #:manifest-url (manifest-url base-url)
   #:data-directory (or (unbox download-root-box) (current-directory))
   #:destination
   (lambda (candidate)
     (cond
       [(appimage-flavor?)
        (define-values (self staged) (appimage-download-target))
        (set-box! appimage-self-box self)
        staged]
       [else
        (build-path (updates-dir (or (unbox download-root-box)
                                     (current-directory)))
                    (artifact-file-name candidate))]))
   #:after-download
   (lambda (verified candidate)
     (define self (unbox appimage-self-box))
     (if self
         (install-appimage! verified self)
         verified))
   #:rollout-bucket (rollout-bucket)
   #:maximum-manifest-bytes (* 4 1024 1024)
   #:maximum-download-bytes maximum-download-bytes))

(define (updates-dir data-dir)
  (build-path data-dir "updates"))

;; ---------- AppImage flavor (Linux installs run from an AppImage) ----------
;;
;; The signed release feed contains a first-class per-architecture AppImage
;; artifact with the exact byte count and SHA-256 digest. Rivet verifies both
;; under the embedded Ed25519 public key before any replacement; mutable
;; .AppImage.sha256 sidecars are never consulted. The verified image downloads
;; beside the running executable (same filesystem for atomic rename), saves
;; the previous version as .previous, and replaces it only after verification.
;; The host may re-exec the new image on user consent; the backup remains
;; available for recovery if the new version fails to launch.

;; $APPIMAGE (set by the AppImage runtime) is inherited by the embedded
;; backend — its presence IS the install shape; no config plumbing needed.
;; platform-symbol is the stable predicate: system-type's os is 'unix on
;; Linux, so an (eq? (system-type 'os) 'linux) guard is never true there
;; (the same trap the threadly suite documents).
(define (appimage-flavor?)
  (and (eq? (platform-symbol) 'linux)
       (let ([self (getenv "APPIMAGE")])
         (and self (not (string=? self ""))))))

(define (appimage-download-target)
  ;; Keep staging on the same filesystem for an atomic final rename; return
  ;; paths end to end (the state publishes path->string of the result).
  (define self-string (getenv "APPIMAGE"))
  (unless (and self-string (non-empty-string? self-string))
    (error 'start-download "APPIMAGE is not set; not running as an AppImage"))
  (define self (string->path self-string))
  ;; Reserve a unique name, then remove the file: a failed verification
  ;; must not strand an empty staging file beside the running image
  ;; (rivet's managed download cleans only its own .partial).
  (define staged
    (make-temporary-file "movebit-update-~a.AppImage" #f (path-only self)))
  (delete-file staged)
  (values self staged))

(define (download-running?)
  (define instance (unbox updater-box))
  (and instance
       (equal? (hash-ref (updater-state instance) 'phase) "downloading")))

(define (cancel-download!)
  (define instance (unbox updater-box))
  (and instance (download-running?)
       (begin (updater-cancel! instance) #t)))

;; Runs on a backend worker thread; the host follows progress via the
;; update-state RPC. Doubles as the cancel gesture (the taskly toggle
;; contract): the start gesture while a download runs IS the cancel — no
;; second RPC, the schema stays put and every host's Cancel button calls
;; this again.
(define (start-download! data-dir)
  (cond
    [(download-running?) (cancel-download!) (void)]
    [else
     (define instance (unbox updater-box))
     (unless (and instance (updater-candidate instance))
       (error 'start-download! "no update is available; run a check first"))
     (set-box! download-root-box data-dir)
     (set-box! phase-override-box #f)
     (updater-download! instance)]))

;; ---------- install preparation (Windows / macOS) ----------
;;
;; The verified archive is staged and an apply-helper script is written; the
;; host exits and the detached helper finishes the swap:
;;   Windows — per-user / portable installs: the zip IS the install layout.
;;     Extract into <data-dir>/updates/staged/ and write apply-update.cmd:
;;     the helper waits for the running app to exit, moves the install
;;     directory aside, robocopys the staged payload over a fresh install
;;     directory (restoring the old one when the copy fails), relaunches,
;;     and retains its helper/trace for diagnostics. MSI installs (Program Files) skip all of that:
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
(define (zip-apply-script install staged pid #:exit-wait-seconds [exit-wait-seconds 120])
  (unless (and (exact-positive-integer? pid) (<= pid 2147483647))
    (raise-argument-error 'zip-apply-script "positive Windows process ID" pid))
  (unless (and (exact-positive-integer? exit-wait-seconds) (<= exit-wait-seconds 600))
    (raise-argument-error 'zip-apply-script "integer timeout from 1 through 600 seconds" exit-wait-seconds))
  (define old (string-append install ".old"))
  (string-append
   "@echo off\r\n"
   "setlocal DisableDelayedExpansion\r\n"
   "set TRACE=%~dp0apply-update-trace.txt\r\n"
   "set \"MOVEBIT_UPDATE_EXE=" install "\\RivetHost.exe\"\r\n"
   "cd /d \"%~dp0\"\r\n"
   "echo [%date% %time%] helper started, waiting for PID "
   (number->string pid) " > \"%TRACE%\"\r\n"
   ;; Wait on one process handle with a deadline, without parsing tasklist
   ;; text or depending on TIMEOUT's interactive console input. Only a
   ;; confirmed missing/exited process permits any filesystem mutation.
   "powershell.exe -NoProfile -NonInteractive -Command \"try { $p = [Diagnostics.Process]::GetProcessById("
   (number->string pid)
   "); } catch [System.ArgumentException] { exit 0 } catch { exit 2 }; try { if ($p.WaitForExit("
   (number->string (* exit-wait-seconds 1000))
   ")) { exit 0 }; exit 1 } catch { exit 2 }\" >> \"%TRACE%\" 2>&1\r\n"
   "if errorlevel 1 goto :waitfail\r\n"
   "echo [%time%] app exited, backing up the old install >> \"%TRACE%\"\r\n"
   "ren \"" install "\" \"" (install-base-name install) ".old\"\r\n"
   "if errorlevel 1 goto :renamefail\r\n"
   "echo [%time%] swapping payload >> \"%TRACE%\"\r\n"
   "robocopy \"" staged "\" \"" install "\" /E /R:2 /W:1 /NFL /NDL /NJH /NJS >> \"%TRACE%\" 2>&1\r\n"
   "set \"MOVEBIT_COPY_EXIT=%errorlevel%\"\r\n"
   "echo [%time%] robocopy exit %MOVEBIT_COPY_EXIT% >> \"%TRACE%\"\r\n"
   "if %MOVEBIT_COPY_EXIT% GEQ 8 goto :copyfail\r\n"
   ;; START does not reliably report CreateProcess/ShellExecute failures.
   ;; Require an observable OS launch result before retiring the old install.
   ;; This is not a full application/backend health acknowledgement.
   "call :launch\r\n"
   "if errorlevel 1 goto :launchfail\r\n"
   "echo [%time%] OS accepted launch, retiring backup >> \"%TRACE%\"\r\n"
   ;; A lingering .old (a file briefly held by antivirus) must not fail the
   ;; update that already succeeded — best effort only.
   "rmdir /s /q \"" old "\" >nul 2>&1\r\n"
   ;; Keep the helper with its trace. CMD may need the file to unwind CALL
   ;; frames; deleting it here can turn a successful update into exit 1.
   ;; write-apply-helper! replaces it on the next explicit update attempt.
   "exit /b 0\r\n"
   ":waitfail\r\n"
   "echo [%time%] old process exit not confirmed; update left unapplied >> \"%TRACE%\"\r\n"
   "> \"%~dp0update-failed.txt\" echo old process exit not confirmed within deadline; update left unapplied\r\n"
   "exit /b 1\r\n"
   ":copyfail\r\n"
   "set \"MOVEBIT_UPDATE_FAILURE=robocopy failed (%MOVEBIT_COPY_EXIT%)\"\r\n"
   "goto :rollback\r\n"
   ":launchfail\r\n"
   "set \"MOVEBIT_UPDATE_FAILURE=updated executable launch failed\"\r\n"
   "goto :rollback\r\n"
   ":rollback\r\n"
   "echo [%time%] %MOVEBIT_UPDATE_FAILURE%, restoring the old install >> \"%TRACE%\"\r\n"
   "rmdir /s /q \"" install "\" >nul 2>&1\r\n"
   "ren \"" old "\" \"" (install-base-name install) "\"\r\n"
   "if errorlevel 1 goto :restorefail\r\n"
   "> \"%~dp0update-failed.txt\" echo %MOVEBIT_UPDATE_FAILURE%\r\n"
   "call :launch\r\n"
   "exit /b 1\r\n"
   ":restorefail\r\n"
   "> \"%~dp0update-failed.txt\" echo restore failed; old install retained beside current install\r\n"
   "exit /b 1\r\n"
   ":renamefail\r\n"
   "echo [%time%] FAILED backup rename >> \"%TRACE%\"\r\n"
   "> \"%~dp0update-failed.txt\" echo backup rename failed\r\n"
   "start \"\" \"" install "\\RivetHost.exe\"\r\n"
   "exit /b 1\r\n"
   ":launch\r\n"
   "powershell.exe -NoProfile -NonInteractive -Command \"try { Start-Process -FilePath $env:MOVEBIT_UPDATE_EXE -WorkingDirectory (Split-Path -LiteralPath $env:MOVEBIT_UPDATE_EXE) -ErrorAction Stop | Out-Null; exit 0 } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }\" >> \"%TRACE%\" 2>&1\r\n"
   "exit /b %errorlevel%\r\n"))

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
        (set-box! phase-override-box "ready-to-apply")
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
        (set-box! phase-override-box "ready-to-apply")
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
