#lang racket/base

;; MoveBit v1 config schema tests: version gate, clamping, tolerance and the
;; clean-install contract (a foreign file is defaults, never guessed at).

(require rackunit
         racket/file
         json
         "../movebit/config.rkt"
         "../movebit/timeutil.rkt")

(define (make-temp-dir prefix)
  (define dir (make-temporary-file (string-append "movebit-" prefix "-~a") 'directory))
  dir)

;; Save_and_load_roundtrip_all_settings
(let* ([dir (make-temp-dir "cfg")]
       [expected (reminder-config 50 40 7 25 #f 25 30 #f #f #f #t "auto"
                             "L" "lively" "top-right" "always"
                             "custom" #t #t #f 1320 420)])
  (check-true (save-config dir expected))
  (define actual (load-config dir))
  (check-equal? (reminder-config-sit-reminder-minutes actual) 50)
  (check-equal? (reminder-config-water-reminder-minutes actual) 40)
  (check-equal? (reminder-config-away-reset-minutes actual) 7)
  (check-equal? (reminder-config-snooze-minutes actual) 25)
  (check-false (reminder-config-micro-break-enabled actual))
  (check-equal? (reminder-config-micro-break-interval-minutes actual) 25)
  (check-equal? (reminder-config-micro-break-duration-seconds actual) 30)
  (check-false (reminder-config-motion-enabled actual))
  (check-false (reminder-config-sound-enabled actual))
  (check-false (reminder-config-auto-check-updates actual))
  (check-true (reminder-config-welcome-shown actual))
  (check-equal? (reminder-config-companion-size actual) "L")
  (check-equal? (reminder-config-companion-motion actual) "lively")
  (check-equal? (reminder-config-companion-dock actual) "top-right")
  (check-equal? (reminder-config-companion-labels actual) "always")
  ;; atomic write: no .tmp residue
  (check-false (file-exists? (build-path dir "config.json.tmp")))
  ;; every write stamps the schema version
  (define on-disk (call-with-input-file (config-path dir) read-json))
  (check-equal? (hash-ref on-disk 'SchemaVersion) config-schema-version)
  (delete-directory/files dir))

;; Dock_top_left_roundtrips_through_the_existing_schema_v2
;; The 4th corner is additive: old profiles and the file version are unchanged.
(let* ([dir (make-temp-dir "dock-top-left")]
       [fresh (default-config)]
       [as-json (hash-set (config->jsexpr fresh) 'CompanionDock "top-left")])
  (define parsed (jsexpr->config as-json))
  (check-equal? (reminder-config-companion-dock parsed) "top-left")
  (check-true (save-config dir parsed))
  (check-equal? (reminder-config-companion-dock (load-config dir)) "top-left")
  (check-equal? (hash-ref (call-with-input-file (config-path dir) read-json)
                          'SchemaVersion)
                config-schema-version)
  (delete-directory/files dir))

;; TrySave_returns_false_when_config_directory_is_a_file
(let* ([dir (make-temp-dir "cfgblk")]
       [blocked-path (build-path dir "not-a-directory")])
  (display-to-file "block directory creation" blocked-path)
  (check-false (save-config blocked-path (default-config)))
  (delete-directory/files dir))

;; Load_clamps_numeric_values_from_disk
(let* ([dir (make-temp-dir "clamp")]
       [path (build-path dir "config.json")])
  (call-with-output-file path
    (lambda (out)
      (write-json
       (hasheq 'SchemaVersion config-schema-version
               'SitReminderMinutes 1
               'WaterReminderMinutes 999
               'AwayResetMinutes 0
               'SnoozeMinutes 999
               'MicroBreakIntervalMinutes 1
               'MicroBreakDurationSeconds 999
               'MotionEnabled "yes")
       out)))
  (define actual (load-config dir))
  (check-equal? (reminder-config-sit-reminder-minutes actual) 10)
  (check-equal? (reminder-config-water-reminder-minutes actual) 180)
  (check-equal? (reminder-config-away-reset-minutes actual) 1)
  (check-equal? (reminder-config-snooze-minutes actual) 60)
  (check-equal? (reminder-config-micro-break-interval-minutes actual) 10)
  (check-equal? (reminder-config-micro-break-duration-seconds actual) 60)
  ;; wrong-typed boolean keeps the default, it is not coerced
  (check-true (reminder-config-motion-enabled actual))
  (check-true (reminder-config-auto-check-updates actual))
  (delete-directory/files dir))

;; Corrupt_json_falls_back_to_defaults
(let* ([dir (make-temp-dir "corrupt")]
       [path (build-path dir "config.json")])
  (display-to-file "{ definitely not json" path)
  (define actual (load-config dir))
  (check-equal? (reminder-config-sit-reminder-minutes actual) 50)
  (check-equal? (reminder-config-water-reminder-minutes actual) 60)
  (check-equal? (reminder-config-snooze-minutes actual) 10)
  (check-true (reminder-config-motion-enabled actual))
  (check-true (reminder-config-auto-check-updates actual))
  (delete-directory/files dir))

;; v1_has_one_gentle_experience_no_forced_break_fields_exist
(let* ([fresh (default-config)])
  ;; The struct has no force-break/duration/skip accessors at all — the old
  ;; fullscreen contract cannot come back through config. Motion starts on,
  ;; sound starts OFF (issue #87's calm default), onboarding has not run.
  (check-true (reminder-config-motion-enabled fresh))
  (check-false (reminder-config-sound-enabled fresh))
  (check-false (reminder-config-welcome-shown fresh))
  (check-equal? (reminder-config-preset fresh) "balanced")
  (check-true (reminder-config-sit-enabled fresh))
  (check-true (reminder-config-water-enabled fresh))
  (check-false (reminder-config-quiet-hours-enabled fresh)))

;; Legacy_v0x_PascalCase_file_without_version_marker_is_foreign
(let* ([dir (make-temp-dir "legacy")]
       [path (build-path dir "config.json")])
  (display-to-file #<<EOF
{
  "SitReminderMinutes": 60,
  "ForceBreakEnabled": true,
  "BreakDurationMinutes": 25,
  "SkipAfterSeconds": 90,
  "WelcomeShown": true
}
EOF
                   path)
  ;; v0.x had no real users: an old file is NOT migrated. A fresh v1 profile
  ;; starts with defaults; the next save overwrites the foreign file.
  (define actual (load-config dir))
  (check-equal? actual (default-config))
  (check-false (reminder-config-welcome-shown actual))
  (delete-directory/files dir))

;; Unknown_future_schema_version_is_also_rejected
(let* ([dir (make-temp-dir "future")]
       [path (build-path dir "config.json")])
  (call-with-output-file path
    (lambda (out)
      (write-json (hash-set (config->jsexpr (default-config))
                            'SchemaVersion
                            (add1 config-schema-version))
                  out)))
  (check-equal? (load-config dir) (default-config))
  (delete-directory/files dir))

;; Missing_version_marker_falls_back_even_if_everything_else_matches
(let* ([dir (make-temp-dir "noversion")]
       [path (build-path dir "config.json")])
  (call-with-output-file path
    (lambda (out)
      (write-json (hash-remove (config->jsexpr (default-config)) 'SchemaVersion)
                  out)))
  (check-equal? (load-config dir) (default-config))
  (delete-directory/files dir))

;; Partial_v1_file_keeps_defaults_for_missing_keys
(let* ([dir (make-temp-dir "partial")]
       [path (build-path dir "config.json")])
  (display-to-file
   (format "{\"SchemaVersion\": ~a, \"SitReminderMinutes\": 60, \"WelcomeShown\": true}"
           config-schema-version)
   path)
  (define actual (load-config dir))
  (check-equal? (reminder-config-sit-reminder-minutes actual) 60)
  (check-equal? (reminder-config-snooze-minutes actual) 10)
  (check-true (reminder-config-welcome-shown actual))
  (delete-directory/files dir))

;; Save_clamps_out_of_range_values_too (clamp on save, per the port contract)
(let* ([dir (make-temp-dir "saveclamp")])
  (save-config dir (reminder-config 1 999 0 999 #t 1 999 "x" #t #t #f "klingon"
                                   "huge" "fast" "center" "sometimes"
                                   "bogus" #f #f #t -5 9999))
  (define actual (load-config dir))
  (check-equal? (reminder-config-sit-reminder-minutes actual) 10)
  (check-equal? (reminder-config-water-reminder-minutes actual) 180)
  (check-equal? (reminder-config-snooze-minutes actual) 60)
  (check-true (reminder-config-motion-enabled actual))
  (check-equal? (reminder-config-language actual) "auto")
  ;; unknown companion choices normalize to the shipped defaults
  (check-equal? (reminder-config-companion-size actual) "M")
  (check-equal? (reminder-config-companion-motion actual) "subtle")
  (check-equal? (reminder-config-companion-dock actual) "bottom-right")
  (check-equal? (reminder-config-companion-labels actual) "cue")
  (delete-directory/files dir))

;; --- issue #87: rhythm presets -------------------------------------------

;; Applying a preset writes the exact published values and the matching label.
(let* ([base (default-config)]
       [gentle (clamp-config (apply-preset base 'gentle))])
  (check-equal? (reminder-config-preset gentle) "gentle")
  (check-equal? (reminder-config-sit-reminder-minutes gentle) 75)
  (check-equal? (reminder-config-water-reminder-minutes gentle) 90)
  (check-equal? (reminder-config-micro-break-interval-minutes gentle) 30)
  (check-equal? (reminder-config-snooze-minutes gentle) 15)
  ;; Applying a preset must not silently change unrelated choices.
  (check-equal? (reminder-config-sound-enabled gentle)
                (reminder-config-sound-enabled base))
  (check-equal? (reminder-config-companion-dock gentle)
                (reminder-config-companion-dock base)))

;; Editing one cadence after a preset makes the label "custom" — the config
;; can never advertise numbers it does not store.
(let* ([edited (clamp-config
                (struct-copy reminder-config
                             (apply-preset (default-config) 'balanced)
                             [sit-reminder-minutes 55]))])
  (check-equal? (reminder-config-preset edited) "custom"))

;; Values that match a preset are reported as that preset even if the stored
;; label was stale or hand-edited.
(let* ([stale (clamp-config
               (struct-copy reminder-config (default-config) [preset "custom"]))])
  (check-equal? (reminder-config-preset stale) "balanced"))

;; Presets and the new switches survive a save/load round-trip.
(let* ([dir (make-temp-dir "preset")]
       [config (clamp-config
                (struct-copy reminder-config
                             (apply-preset (default-config) 'active)
                             [quiet-hours-enabled #t]
                             [quiet-hours-start-minutes 1230]
                             [quiet-hours-end-minutes 480]
                             [water-enabled #f]))])
  (check-true (save-config dir config))
  (define loaded (load-config dir))
  (check-equal? (reminder-config-preset loaded) "active")
  (check-true (reminder-config-quiet-hours-enabled loaded))
  (check-equal? (reminder-config-quiet-hours-start-minutes loaded) 1230)
  (check-equal? (reminder-config-quiet-hours-end-minutes loaded) 480)
  (check-false (reminder-config-water-enabled loaded))
  (delete-directory/files dir))

;; --- issue #87: v2 (0.0.1) migration --------------------------------------

;; A shipped 0.0.1 file keeps the user's cadence, sound and companion choices,
;; gains the new defaults and leaves a one-time backup behind.
(let* ([dir (make-temp-dir "v2-migrate")]
       [path (build-path dir "config.json")]
       [v2 (hasheq 'SchemaVersion 2
                   'SitReminderMinutes 60
                   'WaterReminderMinutes 40
                   'AwayResetMinutes 8
                   'SnoozeMinutes 20
                   'MicroBreakEnabled #f
                   'MicroBreakIntervalMinutes 35
                   'MicroBreakDurationSeconds 25
                   'MotionEnabled #f
                   'SoundEnabled #t
                   'AutoCheckUpdates #f
                   'WelcomeShown #t
                   'Language "zh"
                   'CompanionSize "L"
                   'CompanionMotion "lively"
                   'CompanionDock "top-left"
                   'CompanionLabels "always")])
  (call-with-output-file path
    (lambda (out) (write-json v2 out)))
  (define migrated (load-config dir))
  (check-equal? (reminder-config-sit-reminder-minutes migrated) 60)
  (check-equal? (reminder-config-water-reminder-minutes migrated) 40)
  (check-equal? (reminder-config-snooze-minutes migrated) 20)
  (check-false (reminder-config-micro-break-enabled migrated))
  (check-false (reminder-config-motion-enabled migrated))
  (check-true (reminder-config-sound-enabled migrated))
  (check-true (reminder-config-welcome-shown migrated))
  (check-equal? (reminder-config-language migrated) "zh")
  (check-equal? (reminder-config-companion-dock migrated) "top-left")
  ;; New v3 fields take the safe defaults; the user's old cadence is custom.
  (check-equal? (reminder-config-preset migrated) "custom")
  (check-true (reminder-config-sit-enabled migrated))
  (check-true (reminder-config-water-enabled migrated))
  (check-false (reminder-config-quiet-hours-enabled migrated))
  ;; Backup written exactly once, and it is the original v2 document.
  (define bak (build-path dir "config.json.v2.bak"))
  (check-true (file-exists? bak))
  (check-equal? (hash-ref (call-with-input-file bak read-json) 'SchemaVersion) 2)
  (check-true (save-config dir migrated))
  (check-equal? (hash-ref (call-with-input-file path read-json) 'SchemaVersion)
                config-schema-version)
  (check-equal? (hash-ref (call-with-input-file bak read-json) 'SitReminderMinutes)
                60)
  (delete-directory/files dir))

;; --- issue #87: quiet hours ----------------------------------------------

(define (quiet-config start end)
  (clamp-config (struct-copy reminder-config (default-config)
                           [quiet-hours-enabled #t]
                           [quiet-hours-start-minutes start]
                           [quiet-hours-end-minutes end])))

(define (at hh mm) (local-ymd->ms 2026 1 15 hh mm 0))

(let ([c (quiet-config 1320 420)]) ; 22:00 -> 07:00, wraps midnight
  (check-true (quiet-hours-active? c (at 23 0)))
  (check-true (quiet-hours-active? c (at 0 30)))
  (check-true (quiet-hours-active? c (at 6 59)))
  (check-false (quiet-hours-active? c (at 7 0)))
  (check-false (quiet-hours-active? c (at 12 0)))
  (check-false (quiet-hours-active? c (at 21 59)))
  (check-equal? (quiet-hours-seconds-remaining c (at 23 0)) (* 8 3600))
  (check-equal? (quiet-hours-seconds-remaining c (at 6 0)) 3600)
  (check-equal? (quiet-hours-seconds-remaining c (at 12 0)) 0))

;; A same-day window (09:00 -> 17:00) does not wrap.
(let ([c (quiet-config 540 1020)])
  (check-true (quiet-hours-active? c (at 9 0)))
  (check-true (quiet-hours-active? c (at 16 59)))
  (check-false (quiet-hours-active? c (at 17 0)))
  (check-equal? (quiet-hours-seconds-remaining c (at 16 0)) 3600))

;; start == end means "off", never an all-day pause.
(let ([c (quiet-config 600 600)])
  (check-false (quiet-hours-active? c (at 10 0)))
  (check-equal? (quiet-hours-seconds-remaining c (at 10 0)) 0))

;; Disabled quiet hours never activate.
(let ([c (clamp-config (struct-copy reminder-config (quiet-config 1320 420)
                                     [quiet-hours-enabled #f]))])
  (check-false (quiet-hours-active? c (at 23 0))))
