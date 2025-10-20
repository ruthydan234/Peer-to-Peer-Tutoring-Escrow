(define-constant contract-owner tx-sender)

(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-not-authorized (err u103))
(define-constant err-invalid-amount (err u104))
(define-constant err-session-not-pending (err u105))
(define-constant err-session-not-active (err u106))
(define-constant err-already-confirmed (err u107))
(define-constant err-insufficient-balance (err u108))
(define-constant err-invalid-duration (err u109))
(define-constant err-session-expired (err u110))
(define-constant err-time-conflict (err u111))
(define-constant err-unavailable-slot (err u112))
(define-constant err-invalid-schedule (err u113))
(define-constant err-recurring-not-found (err u114))
(define-constant err-schedule-past-time (err u115))
(define-constant err-invalid-tip-amount (err u116))
(define-constant err-tip-already-sent (err u117))
(define-constant err-session-not-completed (err u118))

(define-constant time-slot-duration u60)
(define-constant max-advance-booking u10080)
(define-constant recurring-weekly u7)
(define-constant recurring-monthly u30)

(define-constant session-pending u0)
(define-constant session-active u1)
(define-constant session-completed u2)
(define-constant session-disputed u3)
(define-constant session-cancelled u4)

(define-data-var next-session-id uint u1)
(define-data-var contract-fee-rate uint u250)
(define-data-var dispute-timeout uint u1440)
(define-data-var next-schedule-id uint u1)
(define-data-var next-recurring-id uint u1)
(define-data-var max-tip-percentage uint u5000)
(define-data-var min-tip-amount uint u10000)

(define-map tutoring-sessions
  { session-id: uint }
  {
    student: principal,
    tutor: principal,
    amount: uint,
    subject: (string-ascii 50),
    duration: uint,
    status: uint,
    created-at: uint,
    student-confirmed: bool,
    tutor-confirmed: bool,
    expires-at: uint
  }
)

(define-map user-sessions
  { user: principal, session-id: uint }
  bool
)

(define-map tutor-profiles
  { tutor: principal }
  {
    hourly-rate: uint,
    subjects: (list 10 (string-ascii 20)),
    rating: uint,
    total-sessions: uint,
    active: bool
  }
)

(define-map session-ratings
  { session-id: uint }
  {
    student-rating: uint,
    tutor-rating: uint,
    feedback: (string-ascii 200)
  }
)

(define-map tutor-availability
  { tutor: principal, day-of-week: uint, time-slot: uint }
  {
    available: bool,
    max-sessions: uint,
    current-bookings: uint
  }
)

(define-map scheduled-sessions
  { schedule-id: uint }
  {
    tutor: principal,
    student: principal,
    scheduled-block: uint,
    duration: uint,
    subject: (string-ascii 50),
    amount: uint,
    auto-created: bool,
    recurring-id: (optional uint),
    session-id: (optional uint)
  }
)

(define-map recurring-sessions
  { recurring-id: uint }
  {
    tutor: principal,
    student: principal,
    frequency: uint,
    duration: uint,
    subject: (string-ascii 50),
    amount: uint,
    day-of-week: uint,
    time-slot: uint,
    next-booking: uint,
    total-sessions: uint,
    active: bool
  }
)

(define-map session-schedules
  { session-id: uint }
  {
    scheduled-block: uint,
    auto-confirm-block: uint,
    reminder-sent: bool,
    schedule-id: uint
  }
)

(define-map session-tips
  { session-id: uint }
  {
    tip-amount: uint,
    tip-sent: bool,
    tip-block: uint,
    tip-message: (optional (string-ascii 100))
  }
)

(define-map tutor-tip-stats
  { tutor: principal }
  {
    total-tips-received: uint,
    tip-count: uint,
    highest-tip: uint,
    average-tip: uint
  }
)

(define-public (set-tutor-availability
  (day-of-week uint)
  (time-slot uint)
  (available bool)
  (max-sessions uint)
)
  (begin
    (asserts! (and (<= day-of-week u6) (>= day-of-week u0)) err-invalid-schedule)
    (asserts! (and (<= time-slot u23) (>= time-slot u0)) err-invalid-schedule)
    (asserts! (is-some (map-get? tutor-profiles { tutor: tx-sender })) err-not-found)
    (ok (map-set tutor-availability
      { tutor: tx-sender, day-of-week: day-of-week, time-slot: time-slot }
      {
        available: available,
        max-sessions: max-sessions,
        current-bookings: u0
      }))
  )
)

(define-public (schedule-session
  (tutor principal)
  (scheduled-block uint)
  (duration uint)
  (subject (string-ascii 50))
  (amount uint)
)
  (let 
    (
      (schedule-id (var-get next-schedule-id))
      (day-of-week (mod (/ scheduled-block u1440) u7))
      (time-slot (mod (/ scheduled-block u60) u24))
      (availability (map-get? tutor-availability { tutor: tutor, day-of-week: day-of-week, time-slot: time-slot }))
    )
    (asserts! (> scheduled-block stacks-block-height) err-schedule-past-time)
    (asserts! (<= scheduled-block (+ stacks-block-height max-advance-booking)) err-invalid-schedule)
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (> duration u0) err-invalid-duration)
    (asserts! (not (is-eq tx-sender tutor)) err-not-authorized)
    (asserts! (is-some (map-get? tutor-profiles { tutor: tutor })) err-not-found)
    
    (match availability
      slot-data
      (begin
        (asserts! (get available slot-data) err-unavailable-slot)
        (asserts! (< (get current-bookings slot-data) (get max-sessions slot-data)) err-time-conflict)
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (map-set scheduled-sessions
          { schedule-id: schedule-id }
          {
            tutor: tutor,
            student: tx-sender,
            scheduled-block: scheduled-block,
            duration: duration,
            subject: subject,
            amount: amount,
            auto-created: false,
            recurring-id: none,
            session-id: none
          })
        (map-set tutor-availability
          { tutor: tutor, day-of-week: day-of-week, time-slot: time-slot }
          (merge slot-data { current-bookings: (+ (get current-bookings slot-data) u1) }))
        (var-set next-schedule-id (+ schedule-id u1))
        (ok schedule-id))
      err-unavailable-slot
    )
  )
)

(define-public (create-recurring-session
  (tutor principal)
  (frequency uint)
  (duration uint)
  (subject (string-ascii 50))
  (amount uint)
  (day-of-week uint)
  (time-slot uint)
)
  (let ((recurring-id (var-get next-recurring-id)))
    (asserts! (or (is-eq frequency recurring-weekly) (is-eq frequency recurring-monthly)) err-invalid-schedule)
    (asserts! (and (<= day-of-week u6) (>= day-of-week u0)) err-invalid-schedule)
    (asserts! (and (<= time-slot u23) (>= time-slot u0)) err-invalid-schedule)
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (> duration u0) err-invalid-duration)
    (asserts! (not (is-eq tx-sender tutor)) err-not-authorized)
    (asserts! (is-some (map-get? tutor-profiles { tutor: tutor })) err-not-found)
    
    (map-set recurring-sessions
      { recurring-id: recurring-id }
      {
        tutor: tutor,
        student: tx-sender,
        frequency: frequency,
        duration: duration,
        subject: subject,
        amount: amount,
        day-of-week: day-of-week,
        time-slot: time-slot,
        next-booking: (calculate-next-booking-block day-of-week time-slot),
        total-sessions: u0,
        active: true
      })
    (var-set next-recurring-id (+ recurring-id u1))
    (ok recurring-id)
  )
)

(define-public (process-recurring-bookings (recurring-id uint))
  (let 
    (
      (recurring-data (unwrap! (map-get? recurring-sessions { recurring-id: recurring-id }) err-recurring-not-found))
      (current-block stacks-block-height)
    )
    (asserts! (get active recurring-data) err-not-found)
    (asserts! (<= (get next-booking recurring-data) current-block) err-schedule-past-time)
    
    (let 
      (
        (schedule-id (var-get next-schedule-id))
        (next-booking-block (+ (get next-booking recurring-data) (* (get frequency recurring-data) u1440)))
      )
      (map-set scheduled-sessions
        { schedule-id: schedule-id }
        {
          tutor: (get tutor recurring-data),
          student: (get student recurring-data),
          scheduled-block: (get next-booking recurring-data),
          duration: (get duration recurring-data),
          subject: (get subject recurring-data),
          amount: (get amount recurring-data),
          auto-created: true,
          recurring-id: (some recurring-id),
          session-id: none
        })
      
      (map-set recurring-sessions
        { recurring-id: recurring-id }
        (merge recurring-data 
          {
            next-booking: next-booking-block,
            total-sessions: (+ (get total-sessions recurring-data) u1)
          }))
      
      (var-set next-schedule-id (+ schedule-id u1))
      (ok schedule-id)
    )
  )
)

(define-public (activate-scheduled-session (schedule-id uint))
  (let 
    (
      (schedule-data (unwrap! (map-get? scheduled-sessions { schedule-id: schedule-id }) err-not-found))
      (session-id (var-get next-session-id))
    )
    (asserts! (is-none (get session-id schedule-data)) err-already-exists)
    (asserts! (<= (get scheduled-block schedule-data) (+ stacks-block-height u60)) err-schedule-past-time)
    
    (map-set tutoring-sessions
      { session-id: session-id }
      {
        student: (get student schedule-data),
        tutor: (get tutor schedule-data),
        amount: (get amount schedule-data),
        subject: (get subject schedule-data),
        duration: (get duration schedule-data),
        status: session-active,
        created-at: stacks-block-height,
        student-confirmed: false,
        tutor-confirmed: false,
        expires-at: (+ (get scheduled-block schedule-data) (get duration schedule-data))
      })
    
    (map-set session-schedules
      { session-id: session-id }
      {
        scheduled-block: (get scheduled-block schedule-data),
        auto-confirm-block: (+ (get scheduled-block schedule-data) (get duration schedule-data)),
        reminder-sent: false,
        schedule-id: schedule-id
      })
    
    (map-set scheduled-sessions
      { schedule-id: schedule-id }
      (merge schedule-data { session-id: (some session-id) }))
    
    (map-set user-sessions { user: (get student schedule-data), session-id: session-id } true)
    (map-set user-sessions { user: (get tutor schedule-data), session-id: session-id } true)
    (var-set next-session-id (+ session-id u1))
    (ok session-id)
  )
)

(define-public (cancel-recurring-session (recurring-id uint))
  (let ((recurring-data (unwrap! (map-get? recurring-sessions { recurring-id: recurring-id }) err-recurring-not-found)))
    (asserts! (or (is-eq tx-sender (get student recurring-data))
                  (is-eq tx-sender (get tutor recurring-data))) err-not-authorized)
    (ok (map-set recurring-sessions
      { recurring-id: recurring-id }
      (merge recurring-data { active: false })))
  )
)

(define-private (calculate-next-booking-block (day-of-week uint) (time-slot uint))
  (let 
    (
      (current-block stacks-block-height)
      (blocks-per-day u1440)
      (current-day (mod (/ current-block blocks-per-day) u7))
      (current-hour (mod (/ current-block u60) u24))
      (days-until-target (if (> day-of-week current-day)
                           (- day-of-week current-day)
                           (+ (- u7 current-day) day-of-week)))
      (target-block (+ current-block (* days-until-target blocks-per-day)))
      (target-hour-block (+ target-block (* time-slot u60)))
    )
    (if (and (is-eq day-of-week current-day) (> time-slot current-hour))
        (+ current-block (* (- time-slot current-hour) u60))
        target-hour-block)
  )
)

(define-public (create-tutor-profile
  (hourly-rate uint) 
  (subjects (list 10 (string-ascii 20))))
  (begin
    (asserts! (> hourly-rate u0) err-invalid-amount)
    (asserts! (> (len subjects) u0) err-invalid-amount)
    (ok (map-set tutor-profiles
      { tutor: tx-sender }
      {
        hourly-rate: hourly-rate,
        subjects: subjects,
        rating: u500,
        total-sessions: u0,
        active: true
      }))))

(define-public (update-tutor-status (active bool))
  (let ((profile (unwrap! (map-get? tutor-profiles { tutor: tx-sender }) err-not-found)))
    (ok (map-set tutor-profiles
      { tutor: tx-sender }
      (merge profile { active: active })))))

(define-public (create-session 
  (tutor principal)
  (subject (string-ascii 50))
  (duration uint)
  (amount uint))
  (let ((session-id (var-get next-session-id))
        (tutor-profile (unwrap! (map-get? tutor-profiles { tutor: tutor }) err-not-found))
        (expires-at (+ stacks-block-height u1440)))
    (asserts! (get active tutor-profile) err-not-authorized)
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (> duration u0) err-invalid-duration)
    (asserts! (not (is-eq tx-sender tutor)) err-not-authorized)
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (map-set tutoring-sessions
      { session-id: session-id }
      {
        student: tx-sender,
        tutor: tutor,
        amount: amount,
        subject: subject,
        duration: duration,
        status: session-pending,
        created-at: stacks-block-height,
        student-confirmed: false,
        tutor-confirmed: false,
        expires-at: expires-at
      })
    (map-set user-sessions { user: tx-sender, session-id: session-id } true)
    (map-set user-sessions { user: tutor, session-id: session-id } true)
    (var-set next-session-id (+ session-id u1))
    (ok session-id)))

(define-public (accept-session (session-id uint))
  (let ((session (unwrap! (map-get? tutoring-sessions { session-id: session-id }) err-not-found)))
    (asserts! (is-eq tx-sender (get tutor session)) err-not-authorized)
    (asserts! (is-eq (get status session) session-pending) err-session-not-pending)
    (asserts! (<= stacks-block-height (get expires-at session)) err-session-expired)
    (ok (map-set tutoring-sessions
      { session-id: session-id }
      (merge session { status: session-active })))))

(define-public (student-confirm-completion (session-id uint))
  (let ((session (unwrap! (map-get? tutoring-sessions { session-id: session-id }) err-not-found)))
    (asserts! (is-eq tx-sender (get student session)) err-not-authorized)
    (asserts! (is-eq (get status session) session-active) err-session-not-active)
    (asserts! (not (get student-confirmed session)) err-already-confirmed)
    (let ((updated-session (merge session { student-confirmed: true })))
      (map-set tutoring-sessions { session-id: session-id } updated-session)
      (if (get tutor-confirmed updated-session)
        (complete-session session-id)
        (ok true)))))

(define-public (tutor-confirm-completion (session-id uint))
  (let ((session (unwrap! (map-get? tutoring-sessions { session-id: session-id }) err-not-found)))
    (asserts! (is-eq tx-sender (get tutor session)) err-not-authorized)
    (asserts! (is-eq (get status session) session-active) err-session-not-active)
    (asserts! (not (get tutor-confirmed session)) err-already-confirmed)
    (let ((updated-session (merge session { tutor-confirmed: true })))
      (map-set tutoring-sessions { session-id: session-id } updated-session)
      (if (get student-confirmed updated-session)
        (complete-session session-id)
        (ok true)))))

(define-private (complete-session (session-id uint))
  (let ((session (unwrap! (map-get? tutoring-sessions { session-id: session-id }) err-not-found))
        (fee (/ (* (get amount session) (var-get contract-fee-rate)) u10000))
        (payout (- (get amount session) fee)))
    (try! (as-contract (stx-transfer? payout tx-sender (get tutor session))))
    (try! (as-contract (stx-transfer? fee tx-sender contract-owner)))
    (map-set tutoring-sessions
      { session-id: session-id }
      (merge session { status: session-completed }))
    (let ((tutor-profile (unwrap! (map-get? tutor-profiles { tutor: (get tutor session) }) err-not-found)))
      (map-set tutor-profiles
        { tutor: (get tutor session) }
        (merge tutor-profile { total-sessions: (+ (get total-sessions tutor-profile) u1) })))
    (ok true)))

(define-public (cancel-session (session-id uint))
  (let ((session (unwrap! (map-get? tutoring-sessions { session-id: session-id }) err-not-found)))
    (asserts! (or (is-eq tx-sender (get student session))
                  (is-eq tx-sender (get tutor session))) err-not-authorized)
    (asserts! (or (is-eq (get status session) session-pending)
                  (is-eq (get status session) session-active)) err-session-not-active)
    (try! (as-contract (stx-transfer? (get amount session) tx-sender (get student session))))
    (ok (map-set tutoring-sessions
      { session-id: session-id }
      (merge session { status: session-cancelled })))))

(define-public (dispute-session (session-id uint))
  (let ((session (unwrap! (map-get? tutoring-sessions { session-id: session-id }) err-not-found)))
    (asserts! (or (is-eq tx-sender (get student session))
                  (is-eq tx-sender (get tutor session))) err-not-authorized)
    (asserts! (is-eq (get status session) session-active) err-session-not-active)
    (ok (map-set tutoring-sessions
      { session-id: session-id }
      (merge session { status: session-disputed })))))

(define-public (resolve-dispute (session-id uint) (award-to-tutor bool))
  (let ((session (unwrap! (map-get? tutoring-sessions { session-id: session-id }) err-not-found)))
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-eq (get status session) session-disputed) err-not-found)
    (if award-to-tutor
      (begin
        (try! (as-contract (stx-transfer? (get amount session) tx-sender (get tutor session))))
        (map-set tutoring-sessions
          { session-id: session-id }
          (merge session { status: session-completed })))
      (begin
        (try! (as-contract (stx-transfer? (get amount session) tx-sender (get student session))))
        (map-set tutoring-sessions
          { session-id: session-id }
          (merge session { status: session-cancelled }))))
    (ok true)))

(define-public (rate-session 
  (session-id uint) 
  (rating uint) 
  (feedback (string-ascii 200)))
  (let ((session (unwrap! (map-get? tutoring-sessions { session-id: session-id }) err-not-found)))
    (asserts! (or (is-eq tx-sender (get student session))
                  (is-eq tx-sender (get tutor session))) err-not-authorized)
    (asserts! (is-eq (get status session) session-completed) err-session-not-active)
    (asserts! (and (>= rating u1) (<= rating u10)) err-invalid-amount)
    (let ((existing-rating (map-get? session-ratings { session-id: session-id })))
      (if (is-eq tx-sender (get student session))
        (map-set session-ratings
          { session-id: session-id }
          (merge (default-to { student-rating: u0, tutor-rating: u0, feedback: "" } existing-rating)
                 { student-rating: rating, feedback: feedback }))
        (map-set session-ratings
          { session-id: session-id }
          (merge (default-to { student-rating: u0, tutor-rating: u0, feedback: "" } existing-rating)
                 { tutor-rating: rating, feedback: feedback })))
      (ok true))))

(define-public (set-contract-fee-rate (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= new-rate u1000) err-invalid-amount)
    (ok (var-set contract-fee-rate new-rate))))

(define-public (withdraw-fees)
  (let ((balance (stx-get-balance (as-contract tx-sender))))
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> balance u0) err-insufficient-balance)
    (as-contract (stx-transfer? balance tx-sender contract-owner))))

(define-read-only (get-tutor-availability (tutor principal) (day-of-week uint) (time-slot uint))
  (map-get? tutor-availability { tutor: tutor, day-of-week: day-of-week, time-slot: time-slot })
)

(define-read-only (get-scheduled-session (schedule-id uint))
  (map-get? scheduled-sessions { schedule-id: schedule-id })
)

(define-read-only (get-recurring-session (recurring-id uint))
  (map-get? recurring-sessions { recurring-id: recurring-id })
)

(define-read-only (get-session-schedule (session-id uint))
  (map-get? session-schedules { session-id: session-id })
)

(define-read-only (check-tutor-availability-window (tutor principal) (start-block uint) (end-block uint))
  (let 
    (
      (start-day (mod (/ start-block u1440) u7))
      (start-hour (mod (/ start-block u60) u24))
      (end-day (mod (/ end-block u1440) u7))
      (end-hour (mod (/ end-block u60) u24))
    )
    (ok {
      start-day: start-day,
      start-hour: start-hour,
      end-day: end-day,
      end-hour: end-hour,
      available: (check-availability-slot tutor start-day start-hour)
    })
  )
)

(define-read-only (get-tutor-weekly-schedule (tutor principal))
  (ok {
    monday: (get-day-availability tutor u1),
    tuesday: (get-day-availability tutor u2),
    wednesday: (get-day-availability tutor u3),
    thursday: (get-day-availability tutor u4),
    friday: (get-day-availability tutor u5),
    saturday: (get-day-availability tutor u6),
    sunday: (get-day-availability tutor u0)
  })
)

(define-read-only (get-upcoming-scheduled-sessions (user principal))
  (let ((current-block stacks-block-height))
    (ok {
      next-session-time: (+ current-block u1440),
      has-upcoming: true,
      total-scheduled: u0
    })
  )
)

(define-read-only (get-recurring-session-summary (user principal))
  (ok {
    total-active: u0,
    weekly-sessions: u0,
    monthly-sessions: u0,
    next-recurring-booking: u0
  })
)

(define-read-only (calculate-optimal-booking-time (tutor principal) (duration uint))
  (let 
    (
      (current-block stacks-block-height)
      (next-available-day u1)
      (next-available-hour u9)
    )
    (ok {
      suggested-block: (+ current-block u1440),
      day-of-week: next-available-day,
      time-slot: next-available-hour,
      duration: duration,
      available: true
    })
  )
)

(define-private (check-availability-slot (tutor principal) (day-of-week uint) (time-slot uint))
  (match (map-get? tutor-availability { tutor: tutor, day-of-week: day-of-week, time-slot: time-slot })
    slot-data (and (get available slot-data) 
                   (< (get current-bookings slot-data) (get max-sessions slot-data)))
    false
  )
)

(define-private (get-day-availability (tutor principal) (day-of-week uint))
  (list
    (check-availability-slot tutor day-of-week u9)
    (check-availability-slot tutor day-of-week u10)
    (check-availability-slot tutor day-of-week u11)
    (check-availability-slot tutor day-of-week u14)
    (check-availability-slot tutor day-of-week u15)
    (check-availability-slot tutor day-of-week u16)
  )
)

(define-read-only (get-session (session-id uint))
  (map-get? tutoring-sessions { session-id: session-id }))

(define-read-only (get-tutor-profile (tutor principal))
  (map-get? tutor-profiles { tutor: tutor }))

(define-read-only (get-session-rating (session-id uint))
  (map-get? session-ratings { session-id: session-id }))

(define-read-only (get-user-session (user principal) (session-id uint))
  (default-to false (map-get? user-sessions { user: user, session-id: session-id })))

(define-read-only (get-next-session-id)
  (var-get next-session-id))

(define-read-only (get-contract-fee-rate)
  (var-get contract-fee-rate))

(define-read-only (get-contract-balance)
  (stx-get-balance (as-contract tx-sender)))

(define-read-only (calculate-fee (amount uint))
  (/ (* amount (var-get contract-fee-rate)) u10000))

(define-read-only (get-session-tip (session-id uint))
  (map-get? session-tips { session-id: session-id }))

(define-read-only (get-tutor-tip-stats (tutor principal))
  (default-to 
    { total-tips-received: u0, tip-count: u0, highest-tip: u0, average-tip: u0 }
    (map-get? tutor-tip-stats { tutor: tutor })))

(define-read-only (calculate-max-tip (session-amount uint))
  (/ (* session-amount (var-get max-tip-percentage)) u10000))

(define-read-only (get-tip-settings)
  (ok {
    max-tip-percentage: (var-get max-tip-percentage),
    min-tip-amount: (var-get min-tip-amount)
  }))

(define-public (send-tip 
  (session-id uint) 
  (tip-amount uint)
  (tip-message (optional (string-ascii 100))))
  (let 
    (
      (session (unwrap! (map-get? tutoring-sessions { session-id: session-id }) err-not-found))
      (existing-tip (map-get? session-tips { session-id: session-id }))
      (max-allowed-tip (calculate-max-tip (get amount session)))
      (tutor-address (get tutor session))
      (current-tip-stats (get-tutor-tip-stats tutor-address))
    )
    (asserts! (is-eq tx-sender (get student session)) err-not-authorized)
    (asserts! (is-eq (get status session) session-completed) err-session-not-completed)
    (asserts! (is-none existing-tip) err-tip-already-sent)
    (asserts! (>= tip-amount (var-get min-tip-amount)) err-invalid-tip-amount)
    (asserts! (<= tip-amount max-allowed-tip) err-invalid-tip-amount)
    (asserts! (> tip-amount u0) err-invalid-tip-amount)
    
    (try! (stx-transfer? tip-amount tx-sender tutor-address))
    
    (map-set session-tips
      { session-id: session-id }
      {
        tip-amount: tip-amount,
        tip-sent: true,
        tip-block: stacks-block-height,
        tip-message: tip-message
      })
    
    (let 
      (
        (new-total-tips (+ (get total-tips-received current-tip-stats) tip-amount))
        (new-tip-count (+ (get tip-count current-tip-stats) u1))
        (new-highest (if (> tip-amount (get highest-tip current-tip-stats)) 
                         tip-amount 
                         (get highest-tip current-tip-stats)))
        (new-average (/ new-total-tips new-tip-count))
      )
      (map-set tutor-tip-stats
        { tutor: tutor-address }
        {
          total-tips-received: new-total-tips,
          tip-count: new-tip-count,
          highest-tip: new-highest,
          average-tip: new-average
        })
    )
    (ok true)
  )
)

(define-public (set-max-tip-percentage (new-percentage uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (<= new-percentage u10000) err-invalid-amount)
    (ok (var-set max-tip-percentage new-percentage))))

(define-public (set-min-tip-amount (new-amount uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> new-amount u0) err-invalid-amount)
    (ok (var-set min-tip-amount new-amount))))
