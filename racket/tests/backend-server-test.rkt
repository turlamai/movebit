#lang racket/base

;; Server-level test over a REAL RVT1 server (same shape as the rivet
;; taskboard example). It proves the Rivet threading model claim the backend
;; depends on: `current-event-emitter` lives on the server reader thread, so a
;; module-top-level thread has NO emitter — but the tick thread started inside
;; the `init` RPC inherits it and its events reach the client. Also exercises
;; the v1 cue lifecycle over the wire: health-cue events, cue-displayed,
;; acknowledge/snooze/dismiss, quiet mode, set-config, get-history, autostart.
;;
;; The virtual clock advances 60 s of work time per `now` read, so one 0.05 s
;; tick accumulates one active minute and a 5-minute water cycle fires after
;; ~5 ticks — no real waiting.

(require rackunit
         racket/async-channel
         racket/bool
         racket/file
         racket/runtime-path
         racket/port
         racket/string
         rivet/backend
         rivet/protocol
         json
         "../../app/backend.rkt"
         "../movebit/config.rkt"
         "../movebit/idle.rkt"
         "../movebit/timeutil.rkt")

;; --- temp data dir with a fast, v1-schema config ----------------------------

(define tmp-dir (make-temporary-file "movebit-server-test-~a" 'directory))
;; Keep the device-id bootstrap out of the developer's real appdata.
(putenv "MOVEBIT_BOOTSTRAP_DIR" (path->string tmp-dir))
(call-with-output-file (build-path tmp-dir "config.json")
  (lambda (out)
    (write-json
     (hasheq 'SchemaVersion config-schema-version
             'SitReminderMinutes 10
             'WaterReminderMinutes 8
             'AwayResetMinutes 1
             'SnoozeMinutes 10
             'MicroBreakEnabled #f
             'AutoCheckUpdates #f)
     out)))

;; --- virtual clock: +60 s of active time per read ---------------------------

(define clock (box (local-ymd->ms 2026 1 1 9 0 0)))
(define (virtual-now-ms)
  (define v (+ (unbox clock) 60000))
  (set-box! clock v)
  v)

;; --- start the server under the injected seams ------------------------------

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))

(define server-thread
  (parameterize ([current-data-dir tmp-dir]
                 [current-now-ms virtual-now-ms]
                 [current-idle-provider
                  (lambda () (make-constant-idle-provider 0))] ; always active
                 [current-tick-interval-seconds 0.05])
    (thread (lambda () (serve server-in server-out)))))

(define hello (read-frame client-in))
(check-equal? (frame-type hello) message:hello)

;; frame pump with deadlines so a regression fails instead of hanging
(define frames (make-async-channel 1024))
(define reader-thread
  (thread (lambda ()
            (let loop ()
              (define f (read-frame client-in))
              (unless (eof-object? f)
                (async-channel-put frames f)
                (loop))))))

(define (next-frame [timeout 10.0])
  (define f (sync/timeout timeout frames))
  (unless f (error 'server-test "timed out waiting for a frame"))
  f)

(define next-id 1)

(define (send-request name . args)
  (define id next-id)
  (set! next-id (add1 next-id))
  (write-frame (frame message:request id (encode-value (cons name args)))
               client-out)
  id)

;; Call an RPC; returns (values result events-seen-while-waiting).
(define (call name . args)
  (define id (apply send-request name args))
  (let loop ([events '()])
    (define f (next-frame))
    (cond
      [(= (frame-type f) message:event)
       (loop (cons (decode-value (frame-payload f)) events))]
      [(= (frame-id f) id)
       (check-equal? (frame-type f) message:response)
       (values (decode-value (frame-payload f)) (reverse events))]
      [else (loop events)])))

;; Wait for the next event with the given name, skipping everything else.
(define (wait-for-event name [timeout 10.0])
  (let loop ()
    (define f (next-frame timeout))
    (define payload (decode-value (frame-payload f)))
    (if (and (= (frame-type f) message:event)
             (string=? (car payload) name))
        payload
        (loop))))

(define (get-state name)
  (define-values (v _) (call "$state/get" name))
  v)

;; The virtual clock advances 60 s per read, so cue timing depends on how
;; many `now` reads an RPC consumed — under load the first cues fire DURING
;; initialize and are drained as response companions. Assertions therefore
;; pin the CONTRACT (shape, kinds, lifecycle), never arrival order or ids.
(define (wait-for-health-cue [timeout 30.0])
  (define f (wait-for-event "health-cue" timeout))
  (list-ref f 1))

(define (health-cue-kind? cue kind)
  (equal? (list-ref cue 1) (list kind)))

(define (find-cue-by-kind candidates wanted)
  ;; wanted is a list of acceptable kind-lists (e.g. '(("water"))).
  (for/first ([c (in-list candidates)]
              #:when (member (list-ref c 1) wanted))
    c))

(define (pending-ids)
  (for/list ([c (in-list (get-state "pending-cues"))])
    (list-ref c 0)))

;; --- 1. init starts the lazy tick thread -----------------------------------

(define-values (init-result init-events) (call "initialize"))
(check-true (void? init-result))

;; HealthCue wire layout: (id kinds action delivery animated due-at-ms
;; expires-at-ms). The FIRST cue to arrive must be a well-formed
;; character-delivered health cue with the ten-minute expiry policy.
(define first-cue (wait-for-health-cue))
(check-true (exact-positive-integer? (list-ref first-cue 0)))
(check-true (pair? (list-ref first-cue 1)))
;; kinds = a priority-ordered subset of sit/water/micro (single kinds are
;; the norm; under load two due kinds can share one merged tick cue).
(check-equal? (list-ref first-cue 1)
              (filter (lambda (k)
                        (member k (list "sit" "water" "micro")))
                      (list-ref first-cue 1)))
(check-equal? (list-ref first-cue 3) "character")
(check-true (list-ref first-cue 4))
(check-true (= (list-ref first-cue 6)
               (+ (list-ref first-cue 5) (* 10 60 1000))))

;; Collect cues until BOTH a sit and a water cue have been seen (bounded by
;; the event timeout; extra merged cues may arrive under load — fine).
(define seen (list first-cue))
(define water-cue
  (or (find-cue-by-kind seen '(("water")))
      (let loop ([tries 0])
        (if (or (> tries 200)
                (and (find-cue-by-kind seen '(("water")))
                     (find-cue-by-kind seen '(("sit")))))
            (find-cue-by-kind seen '(("water")))
            (begin
              (set! seen (cons (wait-for-health-cue) seen))
              (loop (add1 tries)))))))
(define sit-cue
  (or (find-cue-by-kind seen '(("sit")))
      (let loop ([tries 0])
        (if (or (> tries 200) (find-cue-by-kind seen '(("sit"))))
            (find-cue-by-kind seen '(("sit")))
            (begin
              (set! seen (cons (wait-for-health-cue) seen))
              (loop (add1 tries)))))))
(check-true (pair? water-cue) "a water cue must arrive")
(check-equal? (list-ref water-cue 2) "drink-water")
(check-true (pair? sit-cue) "a sit cue must arrive")
(check-equal? (list-ref sit-cue 2) "stand-and-stretch")
(define wc water-cue)
(define sc sit-cue)

;; The pending-cues state reconciles a reconnecting host: both cues are
;; open (or were already settled — assert the union is visible or was
;; acted on; under load one may have expired only after 10 minutes, so
;; at least ONE of them must still be pending).
(check-true (>= (length (get-state "pending-cues")) 1))

;; --- 2. the lifecycle over the wire -----------------------------------------

;; Host reports the sit cue visible, then the user acknowledges it (Done).
;; The Done carries the milestone signal: cue-acknowledged(sit, 1).
(define-values (disp-result disp-ev) (call "cue-displayed" (list-ref sc 0)))
(check-true (void? disp-result))
(define-values (ack-result ack-ev) (call "acknowledge-cue" (list-ref sc 0)))
(check-true (void? ack-result))
(define ack-event
  (for/first ([e (in-list ack-ev)] #:when (string=? (car e) "cue-acknowledged"))
    e))
(check-true (pair? ack-event) "acknowledging a sit cue fires cue-acknowledged")
(check-equal? (list-ref (list-ref ack-event 1) 0) "sit")
(check-equal? (list-ref (list-ref ack-event 1) 1) 1)
;; today's state counts FIRED reminders — a click is never a completion
(define today-after-ack (get-state "today"))
(check-true (>= (list-ref today-after-ack 2) 1))
(check-true (>= (list-ref today-after-ack 1) 10))

;; Hide (dismiss) expires the water cue without claiming completion: the
;; dismissed id leaves the pending-cues reconciliation view.
(define-values (dismiss-result dismiss-ev) (call "dismiss-cue" (list-ref wc 0)))
(check-true (void? dismiss-result))
(check-false (member (list-ref wc 0) (pending-ids)))

;; The dismissed water reminder is not lost: it re-fires on its normal full
;; interval and a fresh cue arrives with a HIGHER id.
(define water-again-id (list-ref wc 0))
(let loop ([tries 0])
  (when (< tries 200)
    (define c (wait-for-health-cue))
    (set! seen (cons c seen))
    (unless (and (health-cue-kind? c "water")
                 (> (list-ref c 0) water-again-id))
      (loop (add1 tries)))))
(define wa
  (for/first ([c (in-list seen)]
              #:when (and (health-cue-kind? c "water")
                          (> (list-ref c 0) water-again-id)))
    c))
(check-true (pair? wa) "the dismissed water reminder re-fires on schedule")

;; Later (snooze) defers by ACTIVE time: accumulator = interval - snooze.
(define wa-id (if (pair? wa) (list-ref wa 0) (list-ref (car (reverse seen)) 0)))
(define-values (snooze-result snooze-ev) (call "snooze-cue" wa-id))
(check-true (void? snooze-result))
(define loops-wire (get-state "loops"))
(define water-loop
  (findf (lambda (l) (string=? (list-ref l 0) "water")) loops-wire))
(check-true (pair? water-loop))
(check-equal? (list-ref water-loop 2) -2)                 ; 8 - 10 accumulated
(check-equal? (list-ref water-loop 1) 10)                 ; due-in = 8 - (-2)
(check-false (member wa-id (pending-ids)))

;; --- 3. quiet mode queues, and exits with a bounded summary -----------------

(define-values (quiet-on-result qon-ev) (call "set-quiet" #t))
(check-true (void? quiet-on-result))
;; While quiet, due reminders QUEUE instead of firing events: wait for at
;; least one queued entry (both cycles may eventually land; one suffices
;; to prove the contract).
(let poll ([tries 0])
  (when (and (< tries 200) (zero? (length (get-state "pending-cues"))))
    (sleep 0.05)
    (poll (add1 tries))))
(check-true (>= (length (get-state "pending-cues")) 1))
;; bounded drain of everything already on the wire: no health-cue event may
;; have fired while quiet (state frames keep flowing and are skipped)
(check-false
 (let drain ()
   (define f (async-channel-try-get frames))
   (and f
        (or (and (= (frame-type f) message:event)
                 (string=? (car (decode-value (frame-payload f))) "health-cue"))
            (drain))))
 "no health-cue event may fire while quiet")

;; Leaving quiet emits ONE summary cue carrying the queued kinds. Under
;; load a concurrently due cue may mix into the same event stream, so take
;; the first health-cue event from the response companions or, failing
;; that, the next one on the wire.
(define-values (quiet-off-result qoff-ev) (call "set-quiet" #f))
(check-true (void? quiet-off-result))
(define quiet-summary
  (or (for/first ([e (in-list qoff-ev)]
                  #:when (string=? (car e) "health-cue"))
        e)
      (wait-for-event "health-cue")))
(define qs (list-ref quiet-summary 1))
;; The summary carries a priority-ordered union of the queued kinds —
;; under load either or both of sit/water may have queued.
(check-true (pair? (list-ref qs 1)))
(check-not-false
 (andmap (lambda (k) (member k (list "sit" "water"))) (list-ref qs 1)))
(check-true (>= (length (get-state "pending-cues")) 1))

;; --- 4. set-config clamps + announces ---------------------------------------

(define-values (cfg-result cfg-events)
  (call "set-config"
        (list 5 999 0 999 #f 99 99 #t #t #t #f "klingon"
              "huge" "fast" "center" "sometimes"
              "balanced" #f #f #f 1320 420)))
(check-true (void? cfg-result))
(define config-event
  (for/first ([e (in-list cfg-events)] #:when (string=? (car e) "config-changed"))
    e))
(check-true (pair? config-event))
(define saved-config (list-ref config-event 1))
(check-equal? (list-ref saved-config 0) 10)    ; sit clamped
(check-equal? (list-ref saved-config 1) 180)   ; water clamped
(check-equal? (list-ref saved-config 11) "auto") ; language normalized
(check-equal? (list-ref saved-config 16) "custom") ; label matches clamped values
(check-false (list-ref saved-config 17))           ; sit switch preserved
;; the published config state carries the same v1 shape
(define cfg-state (get-state "active-config"))
(check-equal? (list-ref cfg-state 1) 180)

;; Quiet hours (#87) pause the live scheduler on the next config write and
;; resume when the user turns them off — the setting must not wait for a
;; restart or for the original window boundary.
(define-values (quiet-hours-on-result _quiet-on-ev)
  (call "set-config"
        (list 50 60 5 10 #t 20 20 #t #f #f #f "en"
              "M" "subtle" "bottom-right" "cue"
              "balanced" #t #t #t 0 1380)))
(check-true (void? quiet-hours-on-result))
(define quiet-paused (get-state "paused"))
(check-true (list-ref quiet-paused 0))
(define-values (quiet-hours-off-result _quiet-off-ev)
  (call "set-config"
        (list 50 60 5 10 #t 20 20 #t #f #f #f "en"
              "M" "subtle" "bottom-right" "cue"
              "balanced" #t #t #f 0 1380)))
(check-true (void? quiet-hours-off-result))
(define quiet-resumed (get-state "paused"))
(check-false (list-ref quiet-resumed 0))

;; --- 5. get-history zero-fills gaps -----------------------------------------


;; Let the periodic ~10-tick stats flush fire (ticks run every 50 ms).
(sleep 1.0)

(define-values (history-wire hist-ev) (call "get-history" 7))
(check-equal? (length history-wire) 7)
(check-true (>= (list-ref (list-ref history-wire 6) 1) 10)) ; today active-mins
(check-true (zero? (list-ref (list-ref history-wire 0) 1))) ; oldest is a hole

;; --- 6. autostart persists through the sandboxed home -----------------------
;; Autostart is domain-owned now (port of AutoStart.cs), so the round-trip
;; writes a real file — point MOVEBIT_AUTOSTART_HOME at a sandbox for the
;; section, whatever thread the RPC handler runs on.

(define autostart-sandbox
  (make-temporary-file "movebit-server-autostart-~a" 'directory))
(define old-autostart-home (getenv "MOVEBIT_AUTOSTART_HOME"))
(putenv "MOVEBIT_AUTOSTART_HOME" (path->string autostart-sandbox))

(define-values (autostart-before asb-ev) (call "get-autostart"))
(check-false autostart-before)
(define-values (set-autostart-result as-set-ev) (call "set-autostart" #t))
(check-true (void? set-autostart-result))
(define-values (autostart-after asa-ev) (call "get-autostart"))
(check-true autostart-after)
(case (system-type)
  [(macosx)
   (check-true
    (file-exists?
     (build-path autostart-sandbox "Library" "LaunchAgents"
                 "com.turlamai.movebit.plist")))])
(define-values (unset-autostart-result asunset-ev) (call "set-autostart" #f))
(check-true (void? unset-autostart-result))
(define-values (autostart-off asoff-ev) (call "get-autostart"))
(check-false autostart-off)

(if old-autostart-home
    (putenv "MOVEBIT_AUTOSTART_HOME" old-autostart-home)
    (putenv "MOVEBIT_AUTOSTART_HOME" ""))
(delete-directory/files autostart-sandbox #:must-exist? #f)

;; --- 7. diagnostics + flush-now touch real behavior -------------------------

(define-values (diag diag-ev) (call "get-diagnostics"))
(check-true (string-contains? diag "movebit"))
(check-true (string-contains? diag "idle-provider: constant"))
;; The version line rides the repo single source (effective-version:
;; rivet-app-info in packaged builds, the update parameter headless) — a
;; semver, never a stale hand-written epoch like "1.4.0-rivet.1".
(check-true (regexp-match? #px"movebit [0-9]+\\.[0-9]+\\.[0-9]+" diag))
(check-false (string-contains? diag "1.4.0"))

(define-values (flush-result flush-ev) (call "flush-now"))
(check-true (void? flush-result))
;; flush-now persists this device's day shard under history/<date>/.
(check-true
 (for/or ([day-dir (in-list (directory-list (build-path tmp-dir "history")
                                            #:build? #t))]
          #:when (directory-exists? day-dir)
          [f (in-list (directory-list day-dir))])
   (string-suffix? (path->string f) ".json"))
 "flush-now must persist today's stats to a day shard")

;; The persisted config is the clamped, version-marked v1 document (immediate
;; auto-save on set-config). The v0.x PascalCase fields are gone.
(define persisted-config
  (call-with-input-file (build-path tmp-dir "config.json") read-json))
(check-equal? (hash-ref persisted-config 'SchemaVersion) config-schema-version)
(check-equal? (hash-ref persisted-config 'WaterReminderMinutes) 60) ; last write was the quiet-hours config
(check-false (hash-has-key? persisted-config 'ForceBreakEnabled))

;; --- diagnostics: JSONL into the data dir --------------------------------------
;;
;; The sink is the Windows console-avoidance contract: diagnostics append as
;; JSONL to <data-dir>/diagnostics.log, never stderr, so a bug report can
;; carry real backend records alongside the copyable failure text.

(let ([log (build-path tmp-dir "diagnostics.log")])
  (when (file-exists? log) (delete-file log))
  (parameterize ([current-data-dir tmp-dir])
    (movebit-diagnostic-sink (hasheq 'event "server-test" 'message "first"))
    (movebit-diagnostic-sink (hasheq 'event "server-test" 'message "second")))
  (define lines
    (call-with-input-file log
      (lambda (in)
        (for/list ([l (in-lines in)] #:unless (string=? l "")) l))))
  (check-equal? (length lines) 2 "each sink call appends exactly one line")
  (for ([l (in-list lines)])
    (define doc (with-input-from-string l read-json))
    (check-equal? (hash-ref doc 'event) "server-test")
    (check-true (string? (hash-ref doc 'ts)) "every record carries a timestamp")))

;; --- shutdown ----------------------------------------------------------------

(write-frame (frame message:shutdown 0 #"") client-out)
(thread-wait server-thread)

(delete-directory/files tmp-dir)
