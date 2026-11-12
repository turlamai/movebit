#lang racket/base

;; MoveBit reminder settings, schema v5 (issue #140): the settings surface
;; shrank to what a user actually needs to touch — language, quiet hours,
;; sound, auto-update — plus two internal-state fields (welcome-shown,
;; companion-free-x/y for the drag-placed home position). Everything else is
;; a product default now: one cadence (50/60/20, see scheduler.rkt), one
;; companion presentation, per-kind reminders always on. "Don't want to be
;; bothered" is Focus (tray) and pause, not config.
;;
;; A file without the v5 schema marker is foreign and falls back to
;; defaults — pre-v5 formats predate the first public release, so no
;; shipped install ever carried one and nothing migrates. The rhythm,
;; companion and per-kind fields of older schemas are gone by design: the
;; product ships exactly one rhythm and one presentation.
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
         ;; quiet hours
         quiet-hours-active?
         quiet-hours-seconds-remaining)

;; v5 (issue #140) is the slim surface. Bump only for a breaking on-disk
;; change; readers reject every other schema version outright.
(define config-schema-version 5)

(struct reminder-config
  (sound-enabled             ; #t — one soft chime per arrival/tearful act
   auto-check-updates        ; #t
   welcome-shown             ; #f — internal first-run state, not a setting
   language                  ; "auto" | "zh" | "en"
   quiet-hours-enabled       ; #f
   quiet-hours-start-minutes ; 1320 = 22:00 local
   quiet-hours-end-minutes   ; 420  = 07:00 local
   ;; Issue #104: a directly placed home position, normalized to the usable
   ;; work area (0..1000 per-mille, origin top-left) so it survives
   ;; monitor/DPI changes and means the same place on every host.
   ;; -1 means "the default corner (bottom-right)". Written by dragging Mubi
   ;; and by move-aside; never exposed as a settings control.
   companion-free-x
   companion-free-y)
  #:transparent)

(define (default-config)
  (reminder-config #t #t #f "auto" #f 1320 420 -1 -1))

(define (clamp v lo hi) (min (max v lo) hi))

(define (valid-language? v) (and (string? v) (member v '("auto" "zh" "en"))))

;; -1 = "default corner"; otherwise a 0..1000 per-mille of the usable work area.
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
  (reminder-config
   (bool-field c reminder-config-sound-enabled)
   (bool-field c reminder-config-auto-check-updates)
   (bool-field c reminder-config-welcome-shown)
   (let ([lang (reminder-config-language c)])
     (if (valid-language? lang) lang "auto"))
   (bool-field c reminder-config-quiet-hours-enabled)
   (clamp (exact-floor (reminder-config-quiet-hours-start-minutes c)) 0 1439)
   (clamp (exact-floor (reminder-config-quiet-hours-end-minutes c)) 0 1439)
   (clamp-free-coord (reminder-config-companion-free-x c))
   (clamp-free-coord (reminder-config-companion-free-y c))))

(define (config->jsexpr c)
  (define clamped (clamp-config c))
  (hasheq 'SchemaVersion config-schema-version
          'SoundEnabled (reminder-config-sound-enabled clamped)
          'AutoCheckUpdates (reminder-config-auto-check-updates clamped)
          'WelcomeShown (reminder-config-welcome-shown clamped)
          'Language (reminder-config-language clamped)
          'QuietHoursEnabled (reminder-config-quiet-hours-enabled clamped)
          'QuietHoursStartMinutes (reminder-config-quiet-hours-start-minutes clamped)
          'QuietHoursEndMinutes (reminder-config-quiet-hours-end-minutes clamped)
          'CompanionFreeX (reminder-config-companion-free-x clamped)
          'CompanionFreeY (reminder-config-companion-free-y clamped)))

;; Tolerant reader with a hard version gate: a file written by any other
;; schema (pre-v5 formats are gone — no shipped install ever carried them;
;; a v0.x PascalCase or future-version file is foreign) uses defaults,
;; never guesses. Within v5, missing keys keep defaults, wrong-typed values
;; keep defaults, numerics are clamped.
(define (jsexpr->config js)
  (if (and (hash? js) (eq? (hash-ref js 'SchemaVersion #f) config-schema-version))
      (read-kept-fields js)
      (default-config)))

;; v5 reader: kept fields only, tolerant types, clamped numbers.
(define (read-kept-fields js)
  (define (int-field key default lo hi)
    (define v (hash-ref js key default))
    (if (exact-integer? v) (clamp v lo hi) default))
  (define (bool-field key default)
    (define v (hash-ref js key default))
    (if (boolean? v) v default))
  (clamp-config
   (reminder-config
    (bool-field 'SoundEnabled #t)
    (bool-field 'AutoCheckUpdates #t)
    (bool-field 'WelcomeShown #f)
    (let ([lang (hash-ref js 'Language "auto")])
      (if (valid-language? lang) lang "auto"))
    (bool-field 'QuietHoursEnabled #f)
    (int-field 'QuietHoursStartMinutes 1320 0 1439)
    (int-field 'QuietHoursEndMinutes 420 0 1439)
    (int-field 'CompanionFreeX -1 -1 1000)
    (int-field 'CompanionFreeY -1 -1 1000))))

(define (config-path directory)
  (build-path directory "config.json"))

;; Load config.json from the given directory. Any read/parse problem falls
;; back to defaults (a tray app keeps working).
(define (load-config directory)
  (with-handlers ([exn:fail? (lambda (_) (default-config))])
    (define js
      (call-with-input-file (config-path directory) read-json))
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

;; --- quiet hours -----------------------------------------------------------
;;
;; Quiet hours are a local wall-clock window, so they wrap across midnight and
;; follow the machine's timezone. They PAUSE the active-time scheduler (the
;; same primitive as "pause 1h"): nothing accumulates and nothing fires while
;; the window is open. A window where start == end is treated as "off" rather
;; than as all-day.

(define day-seconds 86400)

(define (quiet-window-seconds c)
  (modulo (- (* 60 (reminder-config-quiet-hours-end-minutes c))
             (* 60 (reminder-config-quiet-hours-start-minutes c)))
          day-seconds))

;; Seconds since local midnight for the given instant.
(define (local-seconds-of-day now-ms)
  (define d (seconds->date (floor (/ now-ms 1000))))
  (+ (* (date-hour d) 3600) (* (date-minute d) 60) (date-second d)))

(define (quiet-hours-active? c now-ms)
  (and (reminder-config-quiet-hours-enabled c)
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
