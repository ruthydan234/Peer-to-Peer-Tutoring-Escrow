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

(define-constant session-pending u0)
(define-constant session-active u1)
(define-constant session-completed u2)
(define-constant session-disputed u3)
(define-constant session-cancelled u4)

(define-data-var next-session-id uint u1)
(define-data-var contract-fee-rate uint u250)
(define-data-var dispute-timeout uint u1440)

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
