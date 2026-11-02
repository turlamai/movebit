#lang racket/base

;; Daily activity history, sharded per device per day for bring-your-own-sync.
;;
;; Layout under <data-dir>/history/:
;;   <yyyy-MM-dd>/<device-id>.json   one small record per device per day
;;
;; Each device only ever writes its own shard (the counters it observed
;; locally), so Resilio/Syncthing-style folder sync never conflicts: different
;; devices touch different files, and past days are immutable. Cross-device
;; totals are an aggregation at read time — Apple Screen Time semantics:
;; additive counters (active minutes, sit/water/micro) sum across devices,
;; while the longest continuous session keeps per-device meaning and takes the
;; max. Synced files are picked up by history-refresh!, which the backend
;; calls on its 30 s tick, so another machine's minutes land in the totals
;; within a tick of arriving.
;;
;; Migration: the legacy single history.json (one object mapping day keys to
;; records) is imported once under this device's id and renamed
;; history.json.migrated. JSON files, not a database — the data set is tiny,
;; human-readable, and file-level sync is exactly the transport.
;;
;; Conflict copies that sync tools leave behind ("sync-conflict",
;; "syncconflict", "conflicted copy") are ignored by the scanner so a
;; pathological merge cannot double-count a day.

(require json
         racket/file
         racket/format
         racket/math
         racket/path
         racket/string
         "timeutil.rkt")

(provide (struct-out day-record)
         default-day-record
         day-record->jsexpr
         jsexpr->day-record
         aggregate-day-records
         cue-outcome-bump
         cue-outcomes-sum
         cue-outcome-count
         (struct-out history-store)
         make-history-store
         history-load!
         history-refresh!
         history-observe-longest-session!
         history-save-day!
         history-get-recent
         history-device-record
         history-device-ids
         history-days
         retention-days
         history-path)

;; Cue lifecycle outcomes per reminder kind (issue #88): what actually
;; happened after a reminder fired, so history never conflates "we reminded
;; you" with "you did it". The map is kind-symbol -> status-symbol -> count:
;;   presented          the cue was really shown (once per kind per showing)
;;   self-reported-done the user clicked Done — a claim, never proof
;;   snoozed            the user clicked Later
;;   dismissed          the user clicked Hide
;;   expired            shown, then timed out unanswered
;;   not-delivered      timed out while still pending — never made it on
;;                      screen (Focus, shutdown, …)
;; Counts are events, not unique cues: a cue re-presented after Focus counts
;; its presentations, which is the truthful delivery record. Active minutes
;; stay an ESTIMATE derived from idle sampling; nothing here claims verified
;; breaks or health outcomes.
(struct day-record
  (active-minutes sit-breaks water-reminders micro-breaks longest-session-minutes cue-outcomes)
  #:transparent)

;; days: mutable hash date-key -> (mutable hash device-id -> day-record)
(struct history-store (dir device-id days seen)
  #:transparent)

(define (default-day-record)
  (day-record 0 0 0 0 0 (hasheq)))

;; --- cue outcome map helpers -------------------------------------------------

(define (cue-outcome-bump outcomes kind status)
  ;; Pure: return `outcomes` with (kind status) counted once more.
  (define per-kind (hash-ref outcomes kind (hasheq)))
  (hash-set outcomes kind
            (hash-update per-kind status add1 0)))

(define (cue-outcomes-sum a b)
  ;; Pure: union-sum two outcome maps (cross-device aggregation).
  (for/fold ([acc a])
            ([(kind per-kind) (in-hash b)])
    (hash-set acc kind
              (for/fold ([inner (hash-ref acc kind (hasheq))])
                        ([(status n) (in-hash per-kind)])
                (hash-update inner status (lambda (m) (+ m n)) 0)))))

(define (cue-outcome-count outcomes kind status)
  (hash-ref (hash-ref outcomes kind (hasheq)) status 0))

;; JSON shape: {"water": {"presented": 3, "self-reported-done": 1}, …}.
;; Racket's json module uses symbol keys in both directions, so kinds and
;; statuses ride as symbols end to end; unknown kinds/statuses survive the
;; round-trip (forward compatibility) with nonneg int values.
(define (cue-outcomes->jsexpr outcomes)
  (for/hasheq ([(kind per-kind) (in-hash outcomes)]
               #:when (symbol? kind))
    (values kind
            (for/hasheq ([(status n) (in-hash per-kind)]
                         #:when (and (symbol? status)
                                     (exact-nonnegative-integer? n)))
              (values status n)))))

(define (jsexpr->cue-outcomes js)
  (if (hash? js)
      (for/hasheq ([(kind per-kind) (in-hash js)] #:when (hash? per-kind))
        (values (as-symbol kind)
                (for/hasheq ([(status n) (in-hash per-kind)]
                             #:when (exact-nonnegative-integer? n))
                  (values (as-symbol status) n))))
      (hasheq)))

;; JSON keys read back as symbols; accept strings too so a foreign writer
;; (or hand-edit) cannot poison the shard.
(define (as-symbol v)
  (cond [(symbol? v) v]
        [(string? v) (string->symbol v)]
        [else 'invalid]))

(define retention-days 370)

;; The shard this device writes. Kept for diagnostics; the store itself lives
;; in per-day subdirectories now.
(define (history-path directory)
  (build-path directory "history.json"))

(define (nonneg n)
  (if (and (exact-integer? n) (>= n 0)) n 0))

(define (day-record->jsexpr r)
  (hasheq 'ActiveMinutes (day-record-active-minutes r)
          'SitBreaks (day-record-sit-breaks r)
          'WaterReminders (day-record-water-reminders r)
          'MicroBreaks (day-record-micro-breaks r)
          'LongestSessionMinutes (day-record-longest-session-minutes r)
          'CueOutcomes (cue-outcomes->jsexpr (day-record-cue-outcomes r))))

;; Tolerant reader: every field defaults to zero when absent or ill-typed, so
;; legacy records (and half-written ones) still load. Cue outcomes default to
;; an empty map — pre-#88 shards simply observed no lifecycle outcomes.
(define (jsexpr->day-record js)
  (if (hash? js)
      (day-record
       (nonneg (hash-ref js 'ActiveMinutes 0))
       (nonneg (hash-ref js 'SitBreaks 0))
       (nonneg (hash-ref js 'WaterReminders 0))
       (nonneg (hash-ref js 'MicroBreaks 0))
       (nonneg (hash-ref js 'LongestSessionMinutes 0))
       (jsexpr->cue-outcomes (hash-ref js 'CueOutcomes (hasheq))))
      (default-day-record)))

;; Apple Screen Time semantics: additive counters sum across devices (cue
;; outcome events included — each device counts what IT showed, so summing
;; reconstructs the whole without double-counting); the longest continuous
;; session is a per-device property, so it takes the max.
(define (aggregate-day-records records)
  (for/fold ([acc (default-day-record)])
            ([r (in-list records)])
    (day-record (+ (day-record-active-minutes acc)
                   (day-record-active-minutes r))
                (+ (day-record-sit-breaks acc)
                   (day-record-sit-breaks r))
                (+ (day-record-water-reminders acc)
                   (day-record-water-reminders r))
                (+ (day-record-micro-breaks acc)
                   (day-record-micro-breaks r))
                (max (day-record-longest-session-minutes acc)
                     (day-record-longest-session-minutes r))
                (cue-outcomes-sum (day-record-cue-outcomes acc)
                                  (day-record-cue-outcomes r)))))

(define (make-history-store directory device-id)
  (history-store directory device-id (make-hash) (make-hash)))

(define (shard-dir store date-key)
  (build-path (history-store-dir store) "history" date-key))

(define (conflict-copy? file-name)
  (and (regexp-match? #px"(?i:sync-?conflict|conflicted[ _-]?copy)" file-name) #t))

;; --- Loading ---------------------------------------------------------------

(define (read-shard! store date-key device file)
  (define js
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (call-with-input-file file read-json)))
  (when (hash? js)
    (define per-device
      (hash-ref! (history-store-days store) date-key make-hash))
    (hash-set! per-device device (jsexpr->day-record js))))

(define (scan-day-dir! store date-key dir)
  (for ([entry (in-list (with-handlers ([exn:fail? (lambda (_) '())])
                          (directory-list dir)))]
        #:when (file-exists? (build-path dir entry)))
    (define name (path->string entry))
    (unless (string-suffix? name ".tmp")
      (define device (let ([m (regexp-match #px"^([0-9a-f]{8})[.]json$" name)])
                       (and m (cadr m))))
      (cond
        [device
         (define file (build-path dir entry))
         (define stamp (with-handlers ([exn:fail? (lambda (_) 0)])
                         (file-or-directory-modify-seconds file)))
         (define seen (hash-ref (history-store-seen store) file #f))
         (unless (equal? seen stamp)
           (read-shard! store date-key device file)
           (hash-set! (history-store-seen store) file stamp))]
        ;; Not ours to interpret: sync-tool conflict copies and any foreign
        ;; file stay out of the aggregation rather than double-counting.
        [(conflict-copy? name) (void)]))))

;; Scan every day directory, reading only shards that are new or changed
;; since the last pass (mtime-stamped). One directory listing per day is
;; cheap enough for the 30 s tick; the reads are the rare part.
(define (scan-all! store)
  (define root (build-path (history-store-dir store) "history"))
  (for ([entry (in-list (with-handlers ([exn:fail? (lambda (_) '())])
                          (directory-list root)))]
        #:when (directory-exists? (build-path root entry)))
    (define date-key (path->string entry))
    (when (regexp-match? #px"^\\d{4}-\\d{2}-\\d{2}$" date-key)
      (scan-day-dir! store date-key (build-path root entry)))))

;; Full (re)load: import the legacy single file once, then scan every day
;; directory. Unreadable history is not worth crashing a tray app over.
(define (history-load! store)
  (hash-clear! (history-store-days store))
  (hash-clear! (history-store-seen store))
  (migrate-legacy! store)
  (scan-all! store)
  store)

;; Incremental pickup of files that arrived through the folder sync. The
;; backend calls this on its 30 s tick, so another machine's minutes land in
;; the totals within a tick of arriving.
(define (history-refresh! store)
  (scan-all! store)
  store)

;; One-time import of the pre-sync single history.json: its aggregated days
;; become this device's shards (history has no per-device attribution to
;; recover), and the source file is renamed out of the way so a re-import
;; cannot resurrect pruned days.
(define (migrate-legacy! store)
  (define legacy (history-path (history-store-dir store)))
  (define shards-root (build-path (history-store-dir store) "history"))
  (when (and (file-exists? legacy)
             (not (directory-exists? shards-root)))
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (define js (call-with-input-file legacy read-json))
      (when (hash? js)
        (for ([(key value) (in-hash js)])
          (define key-str
            (cond [(string? key) key]
                  [(symbol? key) (symbol->string key)]
                  [else #f]))
          (when (and key-str
                     (regexp-match? #px"^\\d{4}-\\d{2}-\\d{2}$" key-str)
                     (hash? value))
            (write-shard! store key-str
                          (history-store-device-id store)
                          (jsexpr->day-record value)))))
      (define migrated
        (string->path
         (string-append (path->string legacy) ".migrated")))
      (with-handlers ([exn:fail? (lambda (_) (void))])
        (when (file-exists? migrated)
          (delete-file migrated)))
      (rename-file-or-directory legacy migrated #t))))

(define (write-shard! store date-key device record)
  (define dir (shard-dir store date-key))
  (make-directory* dir)
  (define path (build-path dir (string-append device ".json")))
  ;; A unique temp per write: two instances of the same device (a debug
  ;; second launch shares the bootstrap device-id, hence the shard) must
  ;; not share one tmp path — a concurrent rename would move the other
  ;; writer's tmp out from under it and kill that flush with ENOENT. The
  ;; scanner ignores *.tmp, so stragglers never enter the aggregation.
  (define tmp
    (string->path
     (string-append (path->string path) "."
                    (number->string (current-milliseconds)) "."
                    (number->string (random 1000000)) ".tmp")))
  (call-with-output-file tmp
    (lambda (out)
      (write-json (day-record->jsexpr record) out)
      (newline out))
    #:exists 'replace)
  (rename-file-or-directory tmp path #t))

;; --- Writes ----------------------------------------------------------------

;; Keep the live session peak without touching the other counters. The
;; periodic SaveDay flush persists it, so insights add no second write timer.
(define (history-observe-longest-session! store date-key minutes)
  (when (and (exact-integer? minutes) (> minutes 0))
    (define per-device
      (hash-ref! (history-store-days store) date-key make-hash))
    (define existing
      (hash-ref per-device (history-store-device-id store) #f))
    (define record (or existing (default-day-record)))
    (when (> minutes (day-record-longest-session-minutes record))
      (hash-set! per-device
                 (history-store-device-id store)
                 (struct-copy day-record record
                              [longest-session-minutes minutes])))))

;; Upsert this device's shard for one day, prune expired day directories, and
;; persist atomically (write-then-swap). Best-effort by the caller: the
;; in-memory store stays usable when the write fails.
(define (history-save-day! store date-key record [today-key (ms->date-key (now-ms))])
  (define per-device
    (hash-ref! (history-store-days store) date-key make-hash))
  (hash-set! per-device (history-store-device-id store) record)
  (write-shard! store date-key (history-store-device-id store) record)
  (define file
    (build-path (shard-dir store date-key)
                (string-append (history-store-device-id store) ".json")))
  (hash-set! (history-store-seen store) file
             (with-handlers ([exn:fail? (lambda (_) 0)])
               (file-or-directory-modify-seconds file)))
  (prune-expired! store date-key today-key))

;; --- Reads -----------------------------------------------------------------

;; This device's own record for a day (what the local scheduler continues
;; from after a restart — never the cross-device aggregate, or synced minutes
;; from other machines would be double-counted into this device's shard).
(define (history-device-record store date-key)
  (define per-device (hash-ref (history-store-days store) date-key #f))
  (or (and per-device
           (hash-ref per-device (history-store-device-id store) #f))
      (default-day-record)))

(define (history-device-ids store date-key)
  (define per-device (hash-ref (history-store-days store) date-key #f))
  (if per-device
      (sort (hash-map per-device (lambda (k _) k)) string<?)
      '()))

(define (aggregate-day store date-key)
  (define per-device (hash-ref (history-store-days store) date-key #f))
  (if per-device
      (aggregate-day-records (hash-map per-device (lambda (_ v) v)))
      (default-day-record)))

;; The most recent `count` days, oldest first, holes included as zero days.
;; count <= 0 yields an empty list. Cross-device totals, Screen Time style.
(define (history-get-recent store count today-key)
  (if (<= count 0)
      '()
      (for/list ([i (in-range (- count 1) -1 -1)])
        (define key (date-key+days today-key (- i)))
        (cons key (aggregate-day store key)))))

;; Snapshot of the in-memory day table (key -> day-record), for diagnostics.
(define (history-days store)
  (for/hasheq ([(key per-device) (in-hash (history-store-days store))])
    (values key (aggregate-day-records (hash-map per-device (lambda (_ v) v))))))

;; Days kept on disk. Pruning happens on every save. The anchor is the later
;; of the saved day and today, so clock-back situations cannot prune recent
;; data.
(define (prune-expired! store saved-key today-key)
  (define saved (date-key->civil-day saved-key))
  (define today (date-key->civil-day today-key))
  (define anchor
    (cond [(and saved today) (max saved today)]
          [saved saved]
          [today today]
          [else #f]))
  (when anchor
    (define cutoff (- anchor (- retention-days 1)))
    (define root (build-path (history-store-dir store) "history"))
    (for ([entry (in-list (with-handlers ([exn:fail? (lambda (_) '())])
                            (directory-list root)))]
          #:when (directory-exists? (build-path root entry)))
      (define parsed (date-key->civil-day (path->string entry)))
      (when (and parsed (< parsed cutoff))
        (with-handlers ([exn:fail? (lambda (_) (void))])
          (delete-directory/files (build-path root entry)))
        (define prefix (path->string (build-path root entry)))
        (for ([file (in-list (hash-keys (history-store-seen store)))]
              #:when (string-prefix? (path->string file) prefix))
          (hash-remove! (history-store-seen store) file))))))
