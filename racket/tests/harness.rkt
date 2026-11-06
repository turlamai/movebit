#lang racket/base

;; Test harness: drives the scheduler with a virtual clock and a fake idle
;; source. The virtual clock starts
;; at "today 09:00 local" on 2026-01-01, expressed as epoch ms via the system
;; timezone, exactly like TimeZoneInfo.ConvertTimeToUtc(...Unspecified).

(require racket/contract/base
         "../movebit/config.rkt"
         "../movebit/scheduler.rkt"
         "../movebit/timeutil.rkt")

(provide minute-ms
         (struct-out harness)
         make-harness
         h-now-ms
         h-advance!
         h-set-idle!
         h-step!
         h-step-minutes!
         h-fired
         h-fired-count
         h-fired-kinds
         h-day-completed
         h-config
         h-patch-config!
         h-scheduler
         h-sit-cycle-ms
         h-session-ms
         h-active-ms
         h-longest-ms
         h-stats
         h-paused?)

(define minute-ms 60000)

(struct harness (clock            ; box of epoch ms (virtual now)
                 idle-box         ; box of idle seconds or #f
                 scheduler
                 fired-box        ; box of reversed (kind count active-ms)
                 day-completed-box) ; box of reversed archived day-stats
  #:transparent)

(define (make-harness #:sit [sit 45]
                      #:water [water 30]
                      #:away [away 5]
                      #:snooze [snooze 10])
  (define clock (box (local-ymd->ms 2026 1 1 9 0 0)))
  (define idle-box (box 0))
  (define fired-box (box '()))
  (define day-completed-box (box '()))
  ;; Tests opt in to micro breaks explicitly; disabled keeps legacy cases clean.
  (define config (struct-copy reminder-config (default-config)
                                       [sit-reminder-minutes sit]
                                       [water-reminder-minutes water]
                                       [away-reset-minutes away]
                                       [snooze-minutes snooze]
                                       [micro-break-enabled #f] ; tests opt in
                                       [micro-break-interval-minutes 30]
                                       [preset "custom"]))
  (define s
    (make-scheduler config
                    (lambda () (unbox clock))
                    (lambda () (unbox idle-box))
                    #:on-reminder
                    (lambda (kind count active-ms)
                      (set-box! fired-box
                                (cons (list kind count active-ms) (unbox fired-box))))
                    #:on-day-completed
                    (lambda (stats)
                      (set-box! day-completed-box
                                (cons stats (unbox day-completed-box))))))
  (harness clock idle-box s fired-box day-completed-box))

(define (h-now-ms h) (unbox (harness-clock h)))

(define (h-advance! h ms)
  (set-box! (harness-clock h) (+ (unbox (harness-clock h)) ms)))

(define (h-set-idle! h seconds-or-false)
  (set-box! (harness-idle-box h) seconds-or-false))

;; Advance the clock then tick, in one step.
(define (h-step! h ms)
  (h-advance! h ms)
  (scheduler-tick! (harness-scheduler h)))

;; Advance the clock in small ticks, like the real 30-second UI timer would
;; (single big steps get clamped by design, mirroring system-sleep handling).
(define (h-step-minutes! h total [step 5])
  (let loop ([remaining (* total minute-ms)]
             [step-ms (* step minute-ms)])
    (unless (<= remaining 0)
      (define now (if (< remaining step-ms) remaining step-ms))
      (h-step! h now)
      (loop (- remaining now) step-ms))))

(define (h-fired h)
  (reverse (unbox (harness-fired-box h))))

(define (h-day-completed h)
  (reverse (unbox (harness-day-completed-box h))))

(define (h-fired-count h) (length (h-fired h)))

;; Kinds of the reminders that fired, in order.
(define (h-fired-kinds h)
  (map car (h-fired h)))

(define (h-config h) (scheduler-config (harness-scheduler h)))

;; Live-mutate one config field.
(define (h-patch-config! h #:sit [sit 'unset]
                             #:water [water 'unset]
                             #:micro-enabled [micro-enabled 'unset]
                             #:micro-interval [micro-interval 'unset]
                             #:sit-enabled [sit-enabled 'unset]
                             #:water-enabled [water-enabled 'unset])
  (define base (scheduler-config (harness-scheduler h)))
  (define (pick value fallback) (if (eq? value 'unset) fallback value))
  (set-scheduler-config!
   (harness-scheduler h)
   (struct-copy reminder-config base
                [sit-reminder-minutes (pick sit (reminder-config-sit-reminder-minutes base))]
                [water-reminder-minutes (pick water (reminder-config-water-reminder-minutes base))]
                [micro-break-enabled (pick micro-enabled (reminder-config-micro-break-enabled base))]
                [micro-break-interval-minutes (pick micro-interval (reminder-config-micro-break-interval-minutes base))]
                [sit-enabled (pick sit-enabled (reminder-config-sit-enabled base))]
                [water-enabled (pick water-enabled (reminder-config-water-enabled base))]
                [preset "custom"])))

(define (h-scheduler h) (harness-scheduler h))
(define (h-sit-cycle-ms h) (scheduler-sit-cycle-elapsed-ms (harness-scheduler h)))
(define (h-session-ms h) (scheduler-current-session-active-time-ms (harness-scheduler h)))
(define (h-stats h) (scheduler-stats (harness-scheduler h)))
(define (h-active-ms h) (day-stats-active-ms (h-stats h)))
(define (h-longest-ms h) (day-stats-longest-session-ms (h-stats h)))
(define (h-paused? h) (scheduler-paused? (harness-scheduler h)))

;; used by tests that need raw scheduler access
(provide h-scheduler)
