#lang racket/base

;; Port of the scheduler-side cases from MoveBit.Tests/WorkPatternTests.cs.
;; (The two history-format cases live in history-test.rkt.)

(require rackunit
         "harness.rkt"
         "../movebit/scheduler.rkt")

;; Away_break_resets_current_session_but_preserves_daily_peak
(let ([h (make-harness)])
  (h-step-minutes! h 30)
  (check-equal? (h-session-ms h) (* 30 minute-ms))
  (check-equal? (h-longest-ms h) (* 30 minute-ms))
  (h-set-idle! h (* 10 60))
  (h-step-minutes! h 5)
  (check-equal? (h-session-ms h) 0)
  (check-equal? (h-longest-ms h) (* 30 minute-ms))
  (h-set-idle! h 0)
  (h-step-minutes! h 20)
  (check-equal? (h-session-ms h) (* 20 minute-ms))
  (check-equal? (h-longest-ms h) (* 30 minute-ms)))

;; A_self_reported_stand_up_starts_a_new_continuous_session
(let ([h (make-harness)])
  (h-step-minutes! h 25)
  (scheduler-end-session! (h-scheduler h))
  (check-equal? (h-session-ms h) 0)
  (h-step-minutes! h 10)
  (check-equal? (h-session-ms h) (* 10 minute-ms))
  (check-equal? (h-longest-ms h) (* 25 minute-ms)))

;; Pause_resets_the_continuous_session (PauseFor/Resume both zero the session)
(let ([h (make-harness)])
  (h-step-minutes! h 30)
  (scheduler-pause-for! (h-scheduler h) (* 60 minute-ms))
  (check-equal? (h-session-ms h) 0)
  (scheduler-resume! (h-scheduler h))
  (check-equal? (h-session-ms h) 0)
  (h-step-minutes! h 12)
  (check-equal? (h-session-ms h) (* 12 minute-ms)))
