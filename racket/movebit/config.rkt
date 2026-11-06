#lang racket/base

;; MoveBit v1 reminder settings. The v1 reboot (issue #55) broke the old
;; .NET-era PascalCase format on purpose: a file without a known schema marker
;; is foreign and falls back to defaults. Schema v3 (issue #87) adds named
;; rhythm presets, per-kind enable switches and quiet hours; a v2 file — the
;; format shipped with 0.0.1 — is migrated once, preserving the user's cadence,
;; sound choice and companion settings, and leaving a .v2.bak copy behind.
;;
;; Numeric settings are clamped on load AND save; a corrupt or unreadable file
;; silently falls back to defaults — a tray app must never crash on config.

(require json
         racket/bool
         racket/date
         racket/file
         racket/math)

(provide config-schema-version
         (struct-out reminder-config)
         default-config
         clamp-config
         config->jsexpr
         jsexpr->config
         load-config
         save-config
         config-path
         ;; rhythm presets (issue #87)
         preset-names
         preset-cadences
         apply-preset
         effective-preset
         ;; quiet hours (issue #87)
         quiet-hours-active?
         quiet-hours-seconds-remaining)

;; Bump only for a breaking on-disk change; readers migrate v2/v3 and reject
;; everything else.
(define config-schema-version 4)

(struct reminder-config
  (sit-reminder-minutes      ; 50 balanced (10-240, UI step 5)
   water-reminder-minutes    ; 60 balanced (5-180, UI step 5)
   away-reset-minutes        ; 5  (1-60)
   snooze-minutes            ; 10 (5-60, UI step 5)
   micro-break-enabled       ; #t — eye-rest reminders
   micro-break-interval-minutes ; 20 balanced (10-60)
   micro-break-duration-seconds ; 20 (10-60) — suggested eye-rest length
   motion-enabled            ; #t — character animation; #f = static cues
   sound-enabled             ; #f — silent by default since v3
   auto-check-updates        ; #t
   welcome-shown             ; #f
   language                  ; "auto" | "zh" | "en"
   companion-size            ; "S" | "M" | "L" — Mubi BODY height 60/78/104
   companion-motion          ; "still" | "subtle" | "lively"
   companion-dock            ; "bottom-right" | "bottom-left" | "top-right" | "top-left"
   companion-labels          ; "always" | "cue"
   preset                    ; "balanced" | "gentle" | "active" | "custom"
   sit-enabled               ; #t — stand-up reminders on/off
   water-enabled             ; #t — hydration reminders on/off
   quiet-hours-enabled       ; #f
   quiet-hours-start-minutes ; 1320 = 22:00 local
   quiet-hours-end-minutes   ; 420  = 07:00 local
   ;; Issue #104: a directly placed home position, normalized to the usable
   ;; work area (0..1000 per-mille) so it survives monitor/DPI changes.
   ;; -1 means "use the named dock".
   companion-free-x
   companion-free-y)
  #:transparent)

;; v1 has exactly one reminder experience: gentle character-delivered cues.
;; The old force-break/duration/skip fields are gone by design.
;;
;; The balanced preset is the shipped default: water every 60 active minutes,
;; movement every 50 (+ a suggested 5-minute away break), eye rest every 20
;; active minutes for 20 seconds. These are product defaults, never medical
;; claims.
(define (default-config)
  (reminder-config 50 60 5 10 #t 20 20 #t #f #t #f "auto"
                   "M" "subtle" "bottom-right" "cue"
                   "balanced" #t #t #f 1320 420 -1 -1))

(define (clamp v lo hi) (min (max v lo) hi))

(define (valid-language? v) (and (string? v) (member v '("auto" "zh" "en"))))

(define (valid-choice? v choices)
  (and (string? v) (member v choices) #t))

(define companion-size-choices '("S" "M" "L"))
(define companion-motion-choices '("still" "subtle" "lively"))
(define companion-dock-choices '("bottom-right" "bottom-left" "top-right" "top-left"))
(define companion-labels-choices '("always" "cue"))
(define preset-name-choices '("balanced" "gentle" "active" "custom"))

;; --- rhythm presets (issue #87) -------------------------------------------
;;
;; A preset is a named set of exact cadence values. Applying one writes the
;; values AND the label; editing any cadence makes the effective label
;; "custom" so the UI can never claim a preset the numbers do not match.

(define preset-names '(balanced gentle active))

(define (preset-cadences name)
  (case name
    [(balanced) (hasheq 'sit 50 'water 60 'eyes 20 'away 5 'snooze 10 'eye-seconds 20)]
    [(gentle)   (hasheq 'sit 75 'water 90 'eyes 30 'away 5 'snooze 15 'eye-seconds 20)]
    [(active)   (hasheq 'sit 30 'water 45 'eyes 15 'away 5 'snooze 10 'eye-seconds 20)]
    [else #f]))

(define (apply-preset c name)
  (define v (preset-cadences name))
  (unless v (raise-argument-error 'apply-preset "(or/c 'balanced 'gentle 'active)" name))
  (reminder-config
   (hash-ref v 'sit) (hash-ref v 'water) (hash-ref v 'away) (hash-ref v 'snooze)
   (reminder-config-micro-break-enabled c)
   (hash-ref v 'eyes)
   (hash-ref v 'eye-seconds)
   (reminder-config-motion-enabled c)
   (reminder-config-sound-enabled c)
   (reminder-config-auto-check-updates c)
   (reminder-config-welcome-shown c)
   (reminder-config-language c)
   (reminder-config-companion-size c)
   (reminder-config-companion-motion c)
   (reminder-config-companion-dock c)
   (reminder-config-companion-labels c)
   name
   (reminder-config-sit-enabled c)
   (reminder-config-water-enabled c)
   (reminder-config-quiet-hours-enabled c)
   (reminder-config-quiet-hours-start-minutes c)
   (reminder-config-quiet-hours-end-minutes c)
   (reminder-config-companion-free-x c)
   (reminder-config-companion-free-y c)))

;; Derive the label from the values, so a stale or hand-edited config can
;; never advertise a preset it does not implement.
(define (effective-preset c)
  (cond
    [(and (= (reminder-config-sit-reminder-minutes c) 50)
          (= (reminder-config-water-reminder-minutes c) 60)
          (= (reminder-config-micro-break-interval-minutes c) 20)
          (= (reminder-config-snooze-minutes c) 10)
          (= (reminder-config-micro-break-duration-seconds c) 20)) 'balanced]
    [(and (= (reminder-config-sit-reminder-minutes c) 75)
          (= (reminder-config-water-reminder-minutes c) 90)
          (= (reminder-config-micro-break-interval-minutes c) 30)
          (= (reminder-config-snooze-minutes c) 15)
          (= (reminder-config-micro-break-duration-seconds c) 20)) 'gentle]
    [(and (= (reminder-config-sit-reminder-minutes c) 30)
          (= (reminder-config-water-reminder-minutes c) 45)
          (= (reminder-config-micro-break-interval-minutes c) 15)
          (= (reminder-config-snooze-minutes c) 10)
          (= (reminder-config-micro-break-duration-seconds c) 20)) 'active]
    [else 'custom]))

;; --- quiet hours (issue #87) ----------------------------------------------
;;
;; Quiet hours are a local wall-clock window, so they wrap across midnight and
;; follow the machine's timezone. They PAUSE the active-time scheduler (the
;; same primitive as "pause 1h"): nothing accumulates and nothing fires while
;; the window is open. A window where start == end is treated as "off" rather
;; than as all-day.

(define day-seconds 86400)

(define (quiet-hours-enabled? c)
  (reminder-config-quiet-hours-enabled c))

(define (quiet-window-seconds c)
  (modulo (- (* 60 (reminder-config-quiet-hours-end-minutes c))
             (* 60 (reminder-config-quiet-hours-start-minutes c)))
          day-seconds))

;; Seconds since local midnight for the given instant.
(define (local-seconds-of-day now-ms)
  (define d (seconds->date (floor (/ now-ms 1000))))
  (+ (* (date-hour d) 3600) (* (date-minute d) 60) (date-second d)))

(define (quiet-hours-active? c now-ms)
  (and (quiet-hours-enabled? c)
       (positive? (quiet-window-seconds c))
       (< (modulo (- (local-seconds-of-day now-ms)
                     (* 60 (reminder-config-quiet-hours-start-minutes c)))
                  day-seconds)
          (quiet-window-seconds c))))

;; Seconds from `now-ms` to the end of the active quiet window (0 when the
;; window is not active). Drives the scheduler pause so its expiry lands
;; exactly on the window boundary.
(define (quiet-hours-seconds-remaining c now-ms)
  (cond
    [(not (quiet-hours-active? c now-ms)) 0]
    [else
     (- (quiet-window-seconds c)
        (modulo (- (local-seconds-of-day now-ms)
                   (* 60 (reminder-config-quiet-hours-start-minutes c)))
                day-seconds))]))

;; -1 = "use the dock"; otherwise a 0..1000 per-mille of the usable work area.
(define (clamp-free-coord v)
  (if (and (exact-integer? v) (>= v 0))
      (min v 1000)
      -1))

(define (bool-field c accessor)
  (define v (accessor c))
  (if (boolean? v) v (not (false? v))))

;; Clamp every numeric field and normalize choices. Applied on load, on save,
;; and on every RPC write — a persisted file can never drift out of range.
(define (clamp-config c)
  (let* ([clamped
          (reminder-config
           (clamp (exact-floor (reminder-config-sit-reminder-minutes c)) 10 240)
           (clamp (exact-floor (reminder-config-water-reminder-minutes c)) 5 180)
           (clamp (exact-floor (reminder-config-away-reset-minutes c)) 1 60)
           (clamp (exact-floor (reminder-config-snooze-minutes c)) 5 60)
           (bool-field c reminder-config-micro-break-enabled)
           (clamp (exact-floor (reminder-config-micro-break-interval-minutes c)) 10 60)
           (clamp (exact-floor (reminder-config-micro-break-duration-seconds c)) 10 60)
           (bool-field c reminder-config-motion-enabled)
           (bool-field c reminder-config-sound-enabled)
           (bool-field c reminder-config-auto-check-updates)
           (bool-field c reminder-config-welcome-shown)
           (let ([lang (reminder-config-language c)])
             (if (valid-language? lang) lang "auto"))
           (let ([v (reminder-config-companion-size c)])
             (if (valid-choice? v companion-size-choices) v "M"))
           (let ([v (reminder-config-companion-motion c)])
             (if (valid-choice? v companion-motion-choices) v "subtle"))
           (let ([v (reminder-config-companion-dock c)])
             (if (valid-choice? v companion-dock-choices) v "bottom-right"))
           (let ([v (reminder-config-companion-labels c)])
             (if (valid-choice? v companion-labels-choices) v "cue"))
           (let ([v (reminder-config-preset c)])
             (if (valid-choice? v preset-name-choices) v "custom"))
           (bool-field c reminder-config-sit-enabled)
           (bool-field c reminder-config-water-enabled)
           (bool-field c reminder-config-quiet-hours-enabled)
           (clamp (exact-floor (reminder-config-quiet-hours-start-minutes c)) 0 1439)
           (clamp (exact-floor (reminder-config-quiet-hours-end-minutes c)) 0 1439)
           (clamp-free-coord (reminder-config-companion-free-x c))
           (clamp-free-coord (reminder-config-companion-free-y c)))])
    ;; The stored label always agrees with the stored numbers.
    (struct-copy reminder-config clamped
                 [preset (symbol->string (effective-preset clamped))])))

(define (config->jsexpr c)
  (define clamped (clamp-config c))
  (hasheq 'SchemaVersion config-schema-version
          'SitReminderMinutes (reminder-config-sit-reminder-minutes clamped)
          'WaterReminderMinutes (reminder-config-water-reminder-minutes clamped)
          'AwayResetMinutes (reminder-config-away-reset-minutes clamped)
          'SnoozeMinutes (reminder-config-snooze-minutes clamped)
          'MicroBreakEnabled (reminder-config-micro-break-enabled clamped)
          'MicroBreakIntervalMinutes (reminder-config-micro-break-interval-minutes clamped)
          'MicroBreakDurationSeconds (reminder-config-micro-break-duration-seconds clamped)
          'MotionEnabled (reminder-config-motion-enabled clamped)
          'SoundEnabled (reminder-config-sound-enabled clamped)
          'AutoCheckUpdates (reminder-config-auto-check-updates clamped)
          'WelcomeShown (reminder-config-welcome-shown clamped)
          'Language (reminder-config-language clamped)
          'CompanionSize (reminder-config-companion-size clamped)
          'CompanionMotion (reminder-config-companion-motion clamped)
          'CompanionDock (reminder-config-companion-dock clamped)
          'CompanionLabels (reminder-config-companion-labels clamped)
          'Preset (reminder-config-preset clamped)
          'SitEnabled (reminder-config-sit-enabled clamped)
          'WaterEnabled (reminder-config-water-enabled clamped)
          'QuietHoursEnabled (reminder-config-quiet-hours-enabled clamped)
          'QuietHoursStartMinutes (reminder-config-quiet-hours-start-minutes clamped)
          'QuietHoursEndMinutes (reminder-config-quiet-hours-end-minutes clamped)
          'CompanionFreeX (reminder-config-companion-free-x clamped)
          'CompanionFreeY (reminder-config-companion-free-y clamped)))

;; Tolerant reader with a hard version gate: a file written by an unknown
;; schema (v0.x PascalCase, future versions) is foreign — use defaults, never
;; guess. Within a known version, missing keys keep defaults, wrong-typed
;; values keep defaults, numerics are clamped.
(define (jsexpr->config js)
  (cond
    [(and (hash? js)
          (memq (hash-ref js 'SchemaVersion #f) (list 3 config-schema-version)))
     (define (int-field key default lo hi)
       (define v (hash-ref js key default))
       (if (exact-integer? v) (clamp v lo hi) default))
     (define (bool-field key default)
       (define v (hash-ref js key default))
       (if (boolean? v) v default))
     (clamp-config
      (reminder-config
       (int-field 'SitReminderMinutes 50 10 240)
       (int-field 'WaterReminderMinutes 60 5 180)
       (int-field 'AwayResetMinutes 5 1 60)
       (int-field 'SnoozeMinutes 10 5 60)
       (bool-field 'MicroBreakEnabled #t)
       (int-field 'MicroBreakIntervalMinutes 20 10 60)
       (int-field 'MicroBreakDurationSeconds 20 10 60)
       (bool-field 'MotionEnabled #t)
       (bool-field 'SoundEnabled #f)
       (bool-field 'AutoCheckUpdates #t)
       (bool-field 'WelcomeShown #f)
       (let ([lang (hash-ref js 'Language "auto")])
         (if (valid-language? lang) lang "auto"))
       (let ([v (hash-ref js 'CompanionSize "M")])
         (if (valid-choice? v companion-size-choices) v "M"))
       (let ([v (hash-ref js 'CompanionMotion "subtle")])
         (if (valid-choice? v companion-motion-choices) v "subtle"))
       (let ([v (hash-ref js 'CompanionDock "bottom-right")])
         (if (valid-choice? v companion-dock-choices) v "bottom-right"))
       (let ([v (hash-ref js 'CompanionLabels "cue")])
         (if (valid-choice? v companion-labels-choices) v "cue"))
       (let ([v (hash-ref js 'Preset "custom")])
         (if (valid-choice? v preset-name-choices) v "custom"))
       (bool-field 'SitEnabled #t)
       (bool-field 'WaterEnabled #t)
       (bool-field 'QuietHoursEnabled #f)
       (int-field 'QuietHoursStartMinutes 1320 0 1439)
       (int-field 'QuietHoursEndMinutes 420 0 1439)
       (int-field 'CompanionFreeX -1 -1 1000)
       (int-field 'CompanionFreeY -1 -1 1000)))]
    ;; The format shipped with 0.0.1: preserve the user's cadence, sound and
    ;; companion choices; the new switches start enabled, quiet hours off.
    [(and (hash? js) (eq? (hash-ref js 'SchemaVersion #f) 2))
     (define (int-field key default lo hi)
       (define v (hash-ref js key default))
       (if (exact-integer? v) (clamp v lo hi) default))
     (define (bool-field key default)
       (define v (hash-ref js key default))
       (if (boolean? v) v default))
     (clamp-config
      (reminder-config
       (int-field 'SitReminderMinutes 45 10 240)
       (int-field 'WaterReminderMinutes 30 5 180)
       (int-field 'AwayResetMinutes 5 1 60)
       (int-field 'SnoozeMinutes 10 5 60)
       (bool-field 'MicroBreakEnabled #t)
       (int-field 'MicroBreakIntervalMinutes 30 10 60)
       (int-field 'MicroBreakDurationSeconds 20 10 60)
       (bool-field 'MotionEnabled #t)
       (bool-field 'SoundEnabled #t)
       (bool-field 'AutoCheckUpdates #t)
       (bool-field 'WelcomeShown #f)
       (let ([lang (hash-ref js 'Language "auto")])
         (if (valid-language? lang) lang "auto"))
       (let ([v (hash-ref js 'CompanionSize "M")])
         (if (valid-choice? v companion-size-choices) v "M"))
       (let ([v (hash-ref js 'CompanionMotion "subtle")])
         (if (valid-choice? v companion-motion-choices) v "subtle"))
       (let ([v (hash-ref js 'CompanionDock "bottom-right")])
         (if (valid-choice? v companion-dock-choices) v "bottom-right"))
       (let ([v (hash-ref js 'CompanionLabels "cue")])
         (if (valid-choice? v companion-labels-choices) v "cue"))
       "custom" #t #t #f 1320 420 -1 -1))]
    [else (default-config)]))

(define (config-path directory)
  (build-path directory "config.json"))

;; Back up a pre-v3 config exactly once, before this build can overwrite it.
(define (backup-v2-config! directory js)
  (with-handlers ([exn:fail? void])
    (define target (build-path directory "config.json.v2.bak"))
    (unless (file-exists? target)
      (with-output-to-file target #:exists 'error
        (lambda () (write-json js) (newline))))))

;; Load config.json from the given directory. Any read/parse problem falls
;; back to defaults (same failure posture as v0.x: a tray app keeps working).
(define (load-config directory)
  (with-handlers ([exn:fail? (lambda (_) (default-config))])
    (define js
      (call-with-input-file (config-path directory) read-json))
    (when (and (hash? js) (eq? (hash-ref js 'SchemaVersion #f) 2))
      (backup-v2-config! directory js))
    (jsexpr->config js)))

;; Atomic write: config.json.tmp -> rename. Returns #t when the file reached
;; disk, #f otherwise (reminders keep working from in-memory settings).
(define (save-config directory config)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define path (config-path directory))
    (define tmp (build-path directory "config.json.tmp"))
    (make-directory* directory)
    (call-with-output-file tmp
      (lambda (out)
        (write-json (config->jsexpr (clamp-config config)) out)
        (newline out))
      #:exists 'replace)
    (rename-file-or-directory tmp path #t)
    #t))
