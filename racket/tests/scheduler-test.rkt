#lang racket/base

;; Port of MoveBit.Tests/SchedulerTests.cs (one test per xunit [Fact]).

(require rackunit
         "harness.rkt"
         "../movebit/history.rkt"
         "../movebit/scheduler.rkt")

;; Sit_reminder_fires_after_active_time_accumulates
(let ([h (make-harness #:sit 45 #:water 300)])
  (h-step-minutes! h 40)
  (check-equal? (h-fired h) '())
  (h-step-minutes! h 10)
  (check-equal? (h-fired-kinds h) '(sit))
  (check-equal? (day-stats-sit-reminders (h-stats h)) 1)
  (check-equal? (h-active-ms h) (* 50 minute-ms)))

;; Water_reminder_fires_on_its_own_cycle
(let ([h (make-harness #:sit 300 #:water 30)])
  (h-step-minutes! h 35)
  (check-equal? (h-fired-kinds h) '(water))
  (check-equal? (day-stats-water-reminders (h-stats h)) 1))

;; Away_time_does_not_accumulate_and_return_resets_cycles
(let ([h (make-harness #:sit 45 #:water 300)])
  (h-step-minutes! h 40)
  (h-set-idle! h (* 10 60))
  (h-step-minutes! h 20)
  (check-equal? (h-fired h) '())
  (check-equal? (h-active-ms h) (* 40 minute-ms))
  (h-set-idle! h 0)
  (h-step-minutes! h 40)
  (check-equal? (h-fired h) '())
  (h-step-minutes! h 10)
  (check-equal? (h-fired-kinds h) '(sit))
  (check-equal? (h-active-ms h) (* 90 minute-ms)))

;; Pause_blocks_reminders_and_counts_only_time_after_exact_expiry
(let ([h (make-harness)])
  (h-step-minutes! h 20)
  (scheduler-pause-for! (h-scheduler h) (* 60 minute-ms))
  (h-step-minutes! h 50)
  (check-equal? (h-fired h) '())
  (check-true (h-paused? h))
  (check-equal? (h-active-ms h) (* 20 minute-ms))
  ;; pause expires 10 minutes into this interval: only final 5 minutes count
  (h-step-minutes! h 15)
  (check-false (h-paused? h))
  (check-equal? (h-active-ms h) (* 25 minute-ms)))

;; Snooze_re_fires_after_the_delay
(let ([h (make-harness #:sit 45 #:water 300 #:snooze 60)])
  (h-step-minutes! h 50)
  (check-equal? (h-fired-count h) 1)
  (scheduler-snooze! (h-scheduler h) 'sit)
  ;; Snooze is not a timer delay: the accumulator jumps to interval - snooze
  ;; (here negative), so the reminder re-fires after a full 60 active minutes.
  (check-equal? (h-sit-cycle-ms h) 0)
  (h-step-minutes! h 59 1)
  (check-equal? (h-fired-count h) 1)
  (h-step-minutes! h 2 1)
  (check-equal? (h-fired-count h) 2))

;; Day_rollover_resets_stats
(let ([h (make-harness #:sit 45 #:water 300)])
  (h-advance! h (* 14 60 minute-ms))
  (h-step-minutes! h 55)
  (check-true (> (h-active-ms h) 0))
  (h-step-minutes! h 10)
  (check-equal? (h-active-ms h) (* 10 minute-ms))
  (check-equal? (day-stats-sit-reminders (h-stats h)) 0)
  (check-equal? (day-stats-water-reminders (h-stats h)) 0))

;; Huge_delta_is_clamped
(let ([h (make-harness #:sit 45 #:water 300)])
  (h-step! h (* 3 60 minute-ms))
  (check-equal? (h-active-ms h) (* 10 minute-ms))
  (check-equal? (h-fired h) '()))

;; Null_idle_provider_degrades_to_natural_time
(let ([h (make-harness #:sit 45 #:water 300)])
  (h-set-idle! h #f)
  (h-step-minutes! h 50)
  (check-equal? (h-fired-kinds h) '(sit)))

;; Micro_break_fires_on_its_own_cycle_and_survives_long_breaks
(let ([h (make-harness #:sit 300 #:water 300)])
  (h-patch-config! h #:micro-enabled #t #:micro-interval 30)
  (h-step-minutes! h 35)
  (check-equal? (h-fired-kinds h) '(micro))
  (check-equal? (day-stats-micro-breaks (h-stats h)) 1))

;; Micro_break_disabled_never_fires
(let ([h (make-harness #:sit 300 #:water 300)])
  (h-patch-config! h #:micro-enabled #f)
  (h-step-minutes! h 120)
  (check-equal? (h-fired h) '())
  (check-equal? (day-stats-micro-breaks (h-stats h)) 0))

;; Away_return_resets_micro_cycle_too
(let ([h (make-harness #:sit 300 #:water 300)])
  (h-patch-config! h #:micro-enabled #t #:micro-interval 30)
  (h-step-minutes! h 20)
  (h-set-idle! h (* 10 60))
  (h-step-minutes! h 20)
  (h-set-idle! h 0)
  (h-step-minutes! h 20)
  (check-equal? (h-fired h) '())
  (h-step-minutes! h 11)
  (check-equal? (h-fired-kinds h) '(micro)))

;; Day_rollover_archives_the_closing_day_and_resets
(let ([h (make-harness #:sit 300 #:water 300)])
  (h-advance! h (* 14 60 minute-ms))
  (scheduler-tick! (h-scheduler h)) ; 14h delta clamps to 10 minutes
  (h-step-minutes! h 55)
  (h-step-minutes! h 10)
  ;; roll happened on the first step across midnight; the closing day is
  ;; archived BEFORE the reset (day-completed fires first)
  (define archives (h-day-completed h))
  (check-equal? (length archives) 1)
  (check-equal? (day-stats-active-ms (car archives)) (* 65 minute-ms))
  (check-equal? (h-active-ms h) (* 10 minute-ms)))

;; A_self_reported_stand_up_ends_the_continuous_session_but_not_the_cycles
(let ([h (make-harness #:sit 60 #:water 300)])
  (h-step-minutes! h 20)
  (scheduler-end-session! (h-scheduler h))
  (check-equal? (h-session-ms h) 0)
  ;; cycles keep their progress: Done on a cue is a report, not a cycle reset
  (check-equal? (h-sit-cycle-ms h) (* 20 minute-ms))
  (check-equal? (h-fired h) '())
  ;; accumulated active time is untouched: only the session counter resets
  (check-equal? (h-active-ms h) (* 20 minute-ms)))

;; RestoreToday_seeds_persisted_morning_activity_into_a_fresh_session
(let ([h (make-harness)])
  (scheduler-restore-today! (h-scheduler h) (day-record 120 2 3 4 55 (hasheq)))
  (check-equal? (h-active-ms h) (* 120 minute-ms))
  (check-equal? (h-longest-ms h) (* 55 minute-ms))
  (check-equal? (day-stats-sit-reminders (h-stats h)) 2)
  (check-equal? (day-stats-water-reminders (h-stats h)) 3)
  (check-equal? (day-stats-micro-breaks (h-stats h)) 4)
  ;; The new session accumulates on top of the restored morning.
  (h-step-minutes! h 10)
  (check-equal? (h-active-ms h) (* 130 minute-ms)))

;; RestoreToday_is_idempotent_per_day
(let ([h (make-harness)])
  (scheduler-restore-today! (h-scheduler h) (day-record 120 2 3 4 55 (hasheq)))
  (scheduler-restore-today! (h-scheduler h) (day-record 120 2 3 4 55 (hasheq)))
  (check-equal? (h-active-ms h) (* 120 minute-ms))
  (check-equal? (day-stats-sit-reminders (h-stats h)) 2))
