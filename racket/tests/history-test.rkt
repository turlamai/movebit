#lang racket/base

;; History store v2: per-device per-day shards under history/<date>/, read-time
;; aggregation with Apple Screen Time semantics (additive counters sum across
;; devices, longest session maxes), legacy history.json migration, sync-conflict
;; copy skipping, and retention pruning of whole day directories.

(require rackunit
         racket/file
         racket/list
         racket/string
         json
         "../movebit/history.rkt"
         "../movebit/paths.rkt"
         "../movebit/timeutil.rkt")

(define (make-temp-dir prefix)
  (make-temporary-file (string-append "movebit-" prefix "-~a") 'directory))

(define today-key (ms->date-key (now-ms)))

;; SaveDay_roundtrips_through_disk
(let* ([dir (make-temp-dir "hist")]
       [yesterday (date-key+days today-key -1)]
       [store (make-history-store dir "aaaaaaaa")])
  (history-load! store)
  (history-save-day! store yesterday (day-record 123 2 4 6 0 (hasheq)))
  (define reloaded (history-load! (make-history-store dir "aaaaaaaa")))
  (define entry (findf (lambda (e) (string=? (car e) yesterday))
                       (history-get-recent reloaded 3 today-key)))
  (check-true (pair? entry))
  (check-equal? (day-record-active-minutes (cdr entry)) 123)
  (check-equal? (day-record-sit-breaks (cdr entry)) 2)
  (check-equal? (day-record-water-reminders (cdr entry)) 4)
  (check-equal? (day-record-micro-breaks (cdr entry)) 6)
  (delete-directory/files dir))

;; GetRecent_fills_holes_with_zero_days_oldest_first
(let* ([dir (make-temp-dir "holes")]
       [store (make-history-store dir "aaaaaaaa")])
  (history-load! store)
  (history-save-day! store today-key (day-record 90 1 2 3 0 (hasheq)))
  (define week (history-get-recent store 7 today-key))
  (check-equal? (length week) 7)
  (check-equal? (car (car week)) (date-key+days today-key -6))
  (check-equal? (car (list-ref week 6)) today-key)
  (check-equal? (day-record-active-minutes (cdr (list-ref week 6))) 90)
  (check-equal? (day-record-active-minutes (cdr (car week))) 0)
  (for ([day (in-list (take week 6))])
    (check-equal? (day-record-sit-breaks (cdr day)) 0))
  (delete-directory/files dir))

;; SaveDay_overwrites_same_day_device_shard
(let* ([dir (make-temp-dir "over")]
       [store (make-history-store dir "aaaaaaaa")])
  (history-load! store)
  (history-save-day! store today-key (day-record 10 0 0 0 0 (hasheq)))
  (history-save-day! store today-key (day-record 42 1 1 1 0 (hasheq)))
  (define single (history-get-recent store 1 today-key))
  (check-equal? (length single) 1)
  (check-equal? (car (car single)) today-key)
  (check-equal? (day-record-active-minutes (cdr (car single))) 42)
  (delete-directory/files dir))

;; TwoDevices_sum_additive_counters_and_max_longest (Screen Time semantics)
(let* ([dir (make-temp-dir "multi")]
       [desktop (make-history-store dir "aaaaaaaa")]
       [laptop (make-history-store dir "bbbbbbbb")])
  (history-load! desktop)
  (history-load! laptop)
  (history-save-day! desktop today-key (day-record 120 2 3 4 45 (hasheq)))
  (history-save-day! laptop today-key (day-record 60 1 1 2 70 (hasheq)))
  ;; The second store picks the first one's shard up through the folder scan.
  (history-refresh! laptop)
  (define totals (history-get-recent laptop 1 today-key))
  (define r (cdr (car totals)))
  (check-equal? (day-record-active-minutes r) 180)
  (check-equal? (day-record-sit-breaks r) 3)
  (check-equal? (day-record-water-reminders r) 4)
  (check-equal? (day-record-micro-breaks r) 6)
  ;; Longest session is a per-device property: max, never a sum.
  (check-equal? (day-record-longest-session-minutes r) 70)
  (check-equal? (history-device-ids laptop today-key) '("aaaaaaaa" "bbbbbbbb"))
  (delete-directory/files dir))

;; DeviceRecord_returns_this_devices_shard_never_the_aggregate
(let* ([dir (make-temp-dir "ownrec")]
       [desktop (make-history-store dir "aaaaaaaa")]
       [laptop (make-history-store dir "bbbbbbbb")])
  (history-load! desktop)
  (history-save-day! desktop today-key (day-record 120 2 3 4 45 (hasheq)))
  (history-load! laptop)
  (history-save-day! laptop today-key (day-record 60 1 1 2 70 (hasheq)))
  (history-refresh! laptop)
  (check-equal? (day-record-active-minutes (history-device-record laptop today-key))
                60)
  (delete-directory/files dir))

;; Migrates_legacy_single_history_json_into_this_devices_shards
(let* ([dir (make-temp-dir "migr")]
       [yesterday (date-key+days today-key -1)]
       [legacy (build-path dir "history.json")])
  (call-with-output-file legacy
    (lambda (out)
      (write-json
       (hasheq (string->symbol today-key)
               (hasheq 'ActiveMinutes 120 'SitBreaks 2 'WaterReminders 3
                       'MicroBreaks 4 'LongestSessionMinutes 15)
               (string->symbol yesterday)
               (hasheq 'ActiveMinutes 30 'SitBreaks 1 'WaterReminders 1
                       'MicroBreaks 1 'LongestSessionMinutes 5))
       out)))
  (define store (make-history-store dir "aaaaaaaa"))
  (history-load! store)
  ;; The legacy file is renamed away — a re-import cannot resurrect pruned days.
  (check-false (file-exists? legacy))
  (check-true (file-exists? (build-path dir "history.json.migrated")))
  (check-equal? (day-record-active-minutes (history-device-record store today-key))
                120)
  (define week (history-get-recent store 2 today-key))
  (check-equal? (day-record-active-minutes (cdr (car week))) 30)
  (delete-directory/files dir))

;; Migration_skipped_when_shards_already_exist
(let* ([dir (make-temp-dir "migskip")]
       [legacy (build-path dir "history.json")]
       [store (make-history-store dir "aaaaaaaa")])
  (history-load! store)
  (history-save-day! store today-key (day-record 5 0 0 0 0 (hasheq)))
  (call-with-output-file legacy
    (lambda (out) (write-json (hasheq 'junk (hasheq 'ActiveMinutes 999)) out)))
  (define reloaded (make-history-store dir "aaaaaaaa"))
  (history-load! reloaded)
  (check-true (file-exists? legacy))
  (check-equal? (day-record-active-minutes
                 (history-device-record reloaded today-key))
                5)
  (delete-directory/files dir))

;; Sync_conflict_copies_are_ignored
(let* ([dir (make-temp-dir "conf")]
       [store (make-history-store dir "aaaaaaaa")]
       [day-dir (build-path dir "history" today-key)])
  (history-load! store)
  (history-save-day! store today-key (day-record 42 1 1 1 0 (hasheq)))
  ;; What Resilio/Syncthing leave behind on a true content conflict.
  (copy-file (build-path day-dir "aaaaaaaa.json")
             (build-path day-dir "bbbbbbbb.json.sync-conflict-20261012-123456.json"))
  (define reloaded (make-history-store dir "aaaaaaaa"))
  (history-load! reloaded)
  (define r (cdr (car (history-get-recent reloaded 1 today-key))))
  (check-equal? (day-record-active-minutes r) 42)
  (delete-directory/files dir))

;; Refresh_picks_up_shards_synced_in_after_load
(let* ([dir (make-temp-dir "late")]
       [store (make-history-store dir "aaaaaaaa")])
  (history-load! store)
  ;; Another device's shard lands in the synced folder after this store
  ;; already loaded.
  (define day-dir (build-path dir "history" today-key))
  (make-directory* day-dir)
  (call-with-output-file (build-path day-dir "bbbbbbbb.json")
    (lambda (out)
      (write-json
       (day-record->jsexpr (day-record 25 1 2 3 25 (hasheq)))
       out)))
  (history-refresh! store)
  (define r (cdr (car (history-get-recent store 1 today-key))))
  (check-equal? (day-record-active-minutes r) 25)
  (check-equal? (history-device-ids store today-key) '("bbbbbbbb"))
  (delete-directory/files dir))

;; CueOutcomes_roundtrip_through_disk (issue #88)
(let* ([dir (make-temp-dir "outc")]
       [store (make-history-store dir "aaaaaaaa")]
       [outcomes (hash-set (hasheq 'water (hasheq 'presented 3 'self-reported-done 1))
                           'sit (hasheq 'presented 2 'not-delivered 1))])
  (history-load! store)
  (history-save-day! store today-key (day-record 60 1 2 0 0 outcomes))
  (define reloaded (history-load! (make-history-store dir "aaaaaaaa")))
  (define r (cdr (car (history-get-recent reloaded 1 today-key))))
  (check-equal? (day-record-cue-outcomes r) outcomes)
  (check-equal? (cue-outcome-count (day-record-cue-outcomes r) 'water 'presented) 3)
  (check-equal? (cue-outcome-count (day-record-cue-outcomes r) 'sit 'not-delivered) 1)
  (check-equal? (cue-outcome-count (day-record-cue-outcomes r) 'micro 'presented) 0)
  (delete-directory/files dir))

;; CueOutcomes_legacy_shard_without_the_field_loads_as_empty
(let* ([dir (make-temp-dir "legacy")]
       [store (make-history-store dir "aaaaaaaa")])
  (history-load! store)
  (define day-dir (build-path dir "history" today-key))
  (make-directory* day-dir)
  (call-with-output-file (build-path day-dir "aaaaaaaa.json")
    (lambda (out)
      ;; Hand-written pre-#88 shard: no CueOutcomes key, garbage tolerated.
      (write-json (hasheq 'ActiveMinutes 30 'SitBreaks 1) out)))
  (history-refresh! store)
  (define r (history-device-record store today-key))
  (check-equal? (day-record-active-minutes r) 30)
  (check-equal? (day-record-cue-outcomes r) (hasheq))
  (delete-directory/files dir))

;; CueOutcomes_aggregate_across_devices_by_summing_events
(let ([a (day-record 0 0 0 0 0 (hasheq 'water (hasheq 'presented 2 'snoozed 1)))]
      [b (day-record 0 0 0 0 0 (hasheq 'water (hasheq 'presented 3)
                                       'sit (hasheq 'not-delivered 1)))])
  (define agg (aggregate-day-records (list a b)))
  (check-equal? (cue-outcome-count (day-record-cue-outcomes agg) 'water 'presented) 5)
  (check-equal? (cue-outcome-count (day-record-cue-outcomes agg) 'water 'snoozed) 1)
  (check-equal? (cue-outcome-count (day-record-cue-outcomes agg) 'sit 'not-delivered) 1))

;; SaveDay_prunes_day_directories_outside_retention_window
(let* ([dir (make-temp-dir "prune")]
       [store (make-history-store dir "aaaaaaaa")]
       [expired (date-key+days today-key (- retention-days))]
       [oldest-kept (date-key+days today-key (- retention-days 1))])
  (history-load! store)
  (history-save-day! store expired (day-record 10 1 1 1 0 (hasheq)) today-key)
  (history-save-day! store oldest-kept (day-record 20 2 2 2 0 (hasheq)) today-key)
  (history-save-day! store today-key (day-record 30 3 3 3 0 (hasheq)) today-key)
  (check-false (directory-exists? (build-path dir "history" expired)))
  (check-true (directory-exists? (build-path dir "history" oldest-kept)))
  (check-true (directory-exists? (build-path dir "history" today-key)))
  (delete-directory/files dir))

;; Corrupt_shards_start_empty
(let* ([dir (make-temp-dir "badhist")]
       [store (make-history-store dir "aaaaaaaa")]
       [day-dir (build-path dir "history" today-key)])
  (make-directory* day-dir)
  (display-to-file "not json at all" (build-path day-dir "aaaaaaaa.json"))
  (history-load! store)
  (check-equal? (history-get-recent store 3 today-key)
                (list (cons (date-key+days today-key -2) (default-day-record))
                      (cons (date-key+days today-key -1) (default-day-record))
                      (cons today-key (default-day-record))))
  (delete-directory/files dir))

;; ObserveLongestSession_keeps_this_devices_peak
(let* ([dir (make-temp-dir "obs")]
       [store (make-history-store dir "aaaaaaaa")])
  (history-load! store)
  (history-observe-longest-session! store today-key 0)
  (history-observe-longest-session! store today-key -5)
  (check-equal? (day-record-longest-session-minutes
                 (history-device-record store today-key))
                0)
  (history-observe-longest-session! store today-key 47)
  (check-equal? (day-record-longest-session-minutes
                 (history-device-record store today-key))
                47)
  (delete-directory/files dir))

;; TwoInstances_same_device_id_concurrent_saves — a debug second launch
;; shares the bootstrap device-id and writes the same shard. The writers
;; must not share one tmp path (a concurrent rename moves the other
;; writer's tmp away, killing its flush with ENOENT), no exception may
;; escape a save, and the shard stays readable with no tmp residue.
(let* ([dir (make-temp-dir "duo")]
       [a (make-history-store dir "aaaaaaaa")]
       [b (make-history-store dir "aaaaaaaa")])
  (history-load! a)
  (history-load! b)
  (define errors '())
  (define (worker store start)
    (for ([i (in-range 50)])
      (with-handlers ([exn:fail? (lambda (e) (set! errors (cons e errors)))])
        (history-save-day! store today-key (day-record (+ start i) 0 0 0 0 (hasheq))))))
  (define ta (thread (lambda () (worker a 100))))
  (define tb (thread (lambda () (worker b 500))))
  (thread-wait ta)
  (thread-wait tb)
  (check-equal? errors '())
  (define shard (build-path dir "history" today-key "aaaaaaaa.json"))
  (check-true (file-exists? shard))
  (define js (call-with-input-file shard read-json))
  (check-true (hash? js))
  ;; Last rename wins: one writer's final value, never a torn file.
  (check-not-false (memv (hash-ref js 'ActiveMinutes 0) '(149 549)))
  (for ([f (in-list (directory-list (build-path dir "history" today-key)))])
    (check-false (string-suffix? (path->string f) ".tmp")))
  (delete-directory/files dir))


;; A machine's device id must survive restarts: ensure-device-id is the key
;; that names every history shard. Regression: the bounded-repetition POSIX
;; regexp never matched, so a fresh id was generated on every launch and the
;; previous shards became unreadable to this device.
(let ([dir (make-temp-dir "device-id")])
  (define old-bootstrap (getenv "MOVEBIT_BOOTSTRAP_DIR"))
  (putenv "MOVEBIT_BOOTSTRAP_DIR" (path->string dir))
  (dynamic-wind
    void
    (lambda ()
      (define first (ensure-device-id))
      (check-regexp-match #px"^[0-9a-f]{8}$" first)
      (check-equal? (ensure-device-id) first)
      ;; A corrupt/foreign id is replaced with a fresh stable one.
      (call-with-output-file (bootstrap-path)
        (lambda (out) (write-json (hasheq 'device-id "NOT-HEX!") out))
        #:exists 'replace)
      (define repaired (ensure-device-id))
      (check-regexp-match #px"^[0-9a-f]{8}$" repaired)
      (check-equal? (ensure-device-id) repaired))
    (lambda ()
      (if old-bootstrap
          (putenv "MOVEBIT_BOOTSTRAP_DIR" old-bootstrap)
          (putenv "MOVEBIT_BOOTSTRAP_DIR" ""))
      (delete-directory/files dir #:must-exist? #f))))
