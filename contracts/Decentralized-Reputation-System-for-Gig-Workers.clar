(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-unauthorized (err u103))
(define-constant err-invalid-score (err u104))

(define-non-fungible-token reputation-token uint)

(define-map worker-profiles
  { worker: principal }
  {
    total-score: uint,
    review-count: uint,
    average-rating: uint,
    verified: bool
  }
)

(define-map gig-reviews
  { gig-id: uint }
  {
    worker: principal,
    client: principal,
    score: uint,
    timestamp: uint,
    description: (string-ascii 256)
  }
)

(define-data-var last-gig-id uint u0)

(define-public (register-worker)
  (let ((worker tx-sender))
    (if (is-some (get-worker-profile worker))
      err-already-exists
      (begin
        (try! (nft-mint? reputation-token u1 worker))
        (ok (map-set worker-profiles
          { worker: worker }
          {
            total-score: u0,
            review-count: u0,
            average-rating: u0,
            verified: false
          }
        ))
      )
    )
  )
)

(define-public (verify-worker (worker principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (is-some (get-worker-profile worker)) err-not-found)
    (ok (map-set worker-profiles
      { worker: worker }
      (merge (unwrap-panic (get-worker-profile worker))
        { verified: true }
      )
    ))
  )
)

(define-public (submit-review (worker principal) (score uint) (description (string-ascii 256)))
  (let 
    (
      (gig-id (+ (var-get last-gig-id) u1))
      (client tx-sender)
    )
    (asserts! (and (>= score u1) (<= score u5)) err-invalid-score)
    (asserts! (is-some (get-worker-profile worker)) err-not-found)
    (try! (update-worker-stats worker score))
    (try! (check-and-award-badges worker))
    (var-set last-gig-id gig-id)
    (ok (map-set gig-reviews
      { gig-id: gig-id }
      {
        worker: worker,
        client: client,
        score: score,
        timestamp: burn-block-height,
        description: description
      }
    ))
  )
)

(define-private (update-worker-stats (worker principal) (new-score uint))
  (let
    (
      (profile (unwrap! (get-worker-profile worker) err-not-found))
      (new-count (+ (get review-count profile) u1))
      (new-total (+ (get total-score profile) new-score))
      (new-average (/ new-total new-count))
    )
    (ok (map-set worker-profiles
      { worker: worker }
      {
        total-score: new-total,
        review-count: new-count,
        average-rating: new-average,
        verified: (get verified profile)
      }
    ))
  )
)

(define-read-only (get-worker-profile (worker principal))
  (map-get? worker-profiles { worker: worker })
)

(define-read-only (get-review (gig-id uint))
  (map-get? gig-reviews { gig-id: gig-id })
)

(define-read-only (get-worker-reputation (worker principal))
  (let ((profile (unwrap! (get-worker-profile worker) err-not-found)))
    (ok {
      average-rating: (get average-rating profile),
      review-count: (get review-count profile),
      verified: (get verified profile)
    })
  )
)

(define-constant err-dispute-not-found (err u200))
(define-constant err-dispute-already-exists (err u201))
(define-constant err-dispute-closed (err u202))
(define-constant err-insufficient-stake (err u203))
(define-constant err-cannot-vote-own-dispute (err u204))

(define-data-var dispute-counter uint u0)
(define-data-var dispute-stake-amount uint u1000)

(define-map disputes
  { dispute-id: uint }
  {
    gig-id: uint,
    worker: principal,
    client: principal,
    reason: (string-ascii 256),
    status: (string-ascii 20),
    votes-for-worker: uint,
    votes-for-client: uint,
    stake-pool: uint,
    created-at: uint
  }
)

(define-map dispute-votes
  { dispute-id: uint, voter: principal }
  { 
    vote: (string-ascii 10),
    stake: uint
  }
)

(define-public (create-dispute (gig-id uint) (reason (string-ascii 256)))
  (let 
    (
      (dispute-id (+ (var-get dispute-counter) u1))
      (worker tx-sender)
      (review-data (unwrap! (get-review gig-id) err-not-found))
    )
    (asserts! (is-eq worker (get worker review-data)) err-unauthorized)
    (asserts! (is-none (get-dispute-by-gig gig-id)) err-dispute-already-exists)
    (try! (stx-transfer? (var-get dispute-stake-amount) tx-sender (as-contract tx-sender)))
    (var-set dispute-counter dispute-id)
    (ok (map-set disputes
      { dispute-id: dispute-id }
      {
        gig-id: gig-id,
        worker: worker,
        client: (get client review-data),
        reason: reason,
        status: "open",
        votes-for-worker: u0,
        votes-for-client: u0,
        stake-pool: (var-get dispute-stake-amount),
        created-at: burn-block-height
      }
    ))
  )
)

(define-public (vote-on-dispute (dispute-id uint) (vote-for-worker bool) (stake-amount uint))
  (let 
    (
      (dispute (unwrap! (map-get? disputes { dispute-id: dispute-id }) err-dispute-not-found))
      (voter tx-sender)
      (vote-str (if vote-for-worker "worker" "client"))
    )
    (asserts! (is-eq (get status dispute) "open") err-dispute-closed)
    (asserts! (>= stake-amount u100) err-insufficient-stake)
    (asserts! (not (or (is-eq voter (get worker dispute)) (is-eq voter (get client dispute)))) err-cannot-vote-own-dispute)
    (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
    (map-set dispute-votes
      { dispute-id: dispute-id, voter: voter }
      { vote: vote-str, stake: stake-amount }
    )
    (ok (map-set disputes
      { dispute-id: dispute-id }
      (merge dispute
        {
          votes-for-worker: (if vote-for-worker (+ (get votes-for-worker dispute) u1) (get votes-for-worker dispute)),
          votes-for-client: (if vote-for-worker (get votes-for-client dispute) (+ (get votes-for-client dispute) u1)),
          stake-pool: (+ (get stake-pool dispute) stake-amount)
        }
      )
    ))
  )
)

(define-public (resolve-dispute (dispute-id uint))
  (let 
    (
      (dispute (unwrap! (map-get? disputes { dispute-id: dispute-id }) err-dispute-not-found))
      (worker-wins (> (get votes-for-worker dispute) (get votes-for-client dispute)))
    )
    (asserts! (is-eq (get status dispute) "open") err-dispute-closed)
    (asserts! (> (+ (get votes-for-worker dispute) (get votes-for-client dispute)) u2) err-unauthorized)
    (map-set disputes
      { dispute-id: dispute-id }
      (merge dispute { status: (if worker-wins "worker-wins" "client-wins") })
    )
    (if worker-wins
      (try! (stx-transfer? (get stake-pool dispute) (as-contract tx-sender) (get worker dispute)))
      (try! (stx-transfer? (get stake-pool dispute) (as-contract tx-sender) (get client dispute)))
    )
    (ok worker-wins)
  )
)

(define-read-only (get-dispute (dispute-id uint))
  (map-get? disputes { dispute-id: dispute-id })
)

(define-read-only (get-dispute-by-gig (gig-id uint))
  (let ((dispute-1 (map-get? disputes { dispute-id: u1 })))
    (if (and (is-some dispute-1) (is-eq (get gig-id (unwrap-panic dispute-1)) gig-id))
      (some u1)
      none
    )
  )
)

(define-read-only (get-vote (dispute-id uint) (voter principal))
  (map-get? dispute-votes { dispute-id: dispute-id, voter: voter })
)

(define-constant err-skill-not-found (err u300))
(define-constant err-skill-already-exists (err u301))
(define-constant err-invalid-skill-score (err u302))

(define-data-var skill-counter uint u0)

(define-map skills
  { skill-id: uint }
  {
    name: (string-ascii 50),
    category: (string-ascii 30),
    active: bool
  }
)

(define-map worker-skill-ratings
  { worker: principal, skill-id: uint }
  {
    total-score: uint,
    review-count: uint,
    average-rating: uint
  }
)

(define-map skill-reviews
  { review-id: uint }
  {
    worker: principal,
    client: principal,
    skill-id: uint,
    score: uint,
    gig-id: uint,
    timestamp: uint
  }
)

(define-data-var skill-review-counter uint u0)

(define-public (create-skill (name (string-ascii 50)) (category (string-ascii 30)))
  (let ((skill-id (+ (var-get skill-counter) u1)))
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set skill-counter skill-id)
    (ok (map-set skills
      { skill-id: skill-id }
      {
        name: name,
        category: category,
        active: true
      }
    ))
  )
)

(define-public (submit-skill-review (worker principal) (skill-id uint) (score uint) (gig-id uint))
  (let 
    (
      (review-id (+ (var-get skill-review-counter) u1))
      (client tx-sender)
    )
    (asserts! (and (>= score u1) (<= score u5)) err-invalid-skill-score)
    (asserts! (is-some (map-get? skills { skill-id: skill-id })) err-skill-not-found)
    (asserts! (is-some (get-worker-profile worker)) err-not-found)
    (var-set skill-review-counter review-id)
    (ok (map-set skill-reviews
      { review-id: review-id }
      {
        worker: worker,
        client: client,
        skill-id: skill-id,
        score: score,
        gig-id: gig-id,
        timestamp: burn-block-height
      }
    ))
  )
)

(define-private (update-skill-rating (worker principal) (skill-id uint) (new-score uint))
  (let
    (
      (current-rating (default-to 
        { total-score: u0, review-count: u0, average-rating: u0 }
        (map-get? worker-skill-ratings { worker: worker, skill-id: skill-id })
      ))
      (new-count (+ (get review-count current-rating) u1))
      (new-total (+ (get total-score current-rating) new-score))
      (new-average (/ new-total new-count))
    )
    (ok (map-set worker-skill-ratings
      { worker: worker, skill-id: skill-id }
      {
        total-score: new-total,
        review-count: new-count,
        average-rating: new-average
      }
    ))
  )
)

(define-read-only (get-worker-skills (worker principal))
  (ok (list))
)

(define-read-only (get-skill (skill-id uint))
  (map-get? skills { skill-id: skill-id })
)

(define-read-only (get-worker-skill-rating-data (worker principal) (skill-id uint))
  (map-get? worker-skill-ratings { worker: worker, skill-id: skill-id })
)

(define-read-only (get-skill-review (review-id uint))
  (map-get? skill-reviews { review-id: review-id })
)

(define-read-only (get-top-workers-by-skill (skill-id uint))
  (ok (list))
)

(define-constant err-badge-not-found (err u400))
(define-constant err-badge-already-earned (err u401))

(define-data-var badge-counter uint u0)

(define-map badge-definitions
  { badge-id: uint }
  {
    name: (string-ascii 50),
    description: (string-ascii 100),
    badge-type: (string-ascii 20),
    requirement-value: uint,
    active: bool
  }
)

(define-map worker-badges
  { worker: principal, badge-id: uint }
  {
    earned-at: uint,
    current-value: uint
  }
)

(define-public (create-badge (name (string-ascii 50)) (description (string-ascii 100)) (badge-type (string-ascii 20)) (requirement-value uint))
  (let ((badge-id (+ (var-get badge-counter) u1)))
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set badge-counter badge-id)
    (ok (map-set badge-definitions
      { badge-id: badge-id }
      {
        name: name,
        description: description,
        badge-type: badge-type,
        requirement-value: requirement-value,
        active: true
      }
    ))
  )
)

(define-public (check-and-award-badges (worker principal))
  (let 
    (
      (profile (unwrap! (get-worker-profile worker) err-not-found))
      (review-count (get review-count profile))
      (average-rating (get average-rating profile))
    )
    (begin
      (try! (check-review-milestone-badges worker review-count))
      (try! (check-rating-milestone-badges worker average-rating))
      (ok true)
    )
  )
)

(define-private (check-review-milestone-badges (worker principal) (review-count uint))
  (begin
    (if (and (>= review-count u10) (is-none (get-worker-badge worker u1)))
      (begin (try! (award-badge worker u1 review-count)) true)
      false
    )
    (if (and (>= review-count u50) (is-none (get-worker-badge worker u2)))
      (begin (try! (award-badge worker u2 review-count)) true)
      false
    )
    (if (and (>= review-count u100) (is-none (get-worker-badge worker u3)))
      (begin (try! (award-badge worker u3 review-count)) true)
      false
    )
    (ok true)
  )
)

(define-private (check-rating-milestone-badges (worker principal) (average-rating uint))
  (begin
    (if (and (>= average-rating u45) (is-none (get-worker-badge worker u4)))
      (begin (try! (award-badge worker u4 average-rating)) true)
      false
    )
    (if (and (is-eq average-rating u50) (is-none (get-worker-badge worker u5)))
      (begin (try! (award-badge worker u5 average-rating)) true)
      false
    )
    (ok true)
  )
)

(define-private (award-badge (worker principal) (badge-id uint) (current-value uint))
  (let ((badge-def (unwrap! (get-badge-definition badge-id) err-badge-not-found)))
    (asserts! (get active badge-def) err-badge-not-found)
    (ok (map-set worker-badges
      { worker: worker, badge-id: badge-id }
      {
        earned-at: burn-block-height,
        current-value: current-value
      }
    ))
  )
)

(define-public (initialize-default-badges)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (try! (create-badge "Rising Star" "Complete 10 gigs" "milestone" u10))
    (try! (create-badge "Veteran" "Complete 50 gigs" "milestone" u50))
    (try! (create-badge "Elite" "Complete 100 gigs" "milestone" u100))
    (try! (create-badge "Top Rated" "Maintain 4.5+ average rating" "rating" u45))
    (try! (create-badge "Perfect Score" "Achieve 5.0 average rating" "rating" u50))
    (ok true)
  )
)

(define-read-only (get-badge-definition (badge-id uint))
  (map-get? badge-definitions { badge-id: badge-id })
)

(define-read-only (get-worker-badge (worker principal) (badge-id uint))
  (map-get? worker-badges { worker: worker, badge-id: badge-id })
)

(define-read-only (get-worker-badge-count (worker principal))
  (let
    (
      (badge-1 (get-worker-badge worker u1))
      (badge-2 (get-worker-badge worker u2))
      (badge-3 (get-worker-badge worker u3))
      (badge-4 (get-worker-badge worker u4))
      (badge-5 (get-worker-badge worker u5))
    )
    (+ 
      (if (is-some badge-1) u1 u0)
      (if (is-some badge-2) u1 u0)
      (if (is-some badge-3) u1 u0)
      (if (is-some badge-4) u1 u0)
      (if (is-some badge-5) u1 u0)
    )
  )
)

(define-constant err-client-not-found (err u500))
(define-constant err-client-already-exists (err u501))
(define-constant err-no-gig-history (err u502))
(define-constant err-already-rated-client (err u503))

(define-data-var client-review-counter uint u0)

(define-map client-profiles
  { client: principal }
  {
    total-score: uint,
    review-count: uint,
    average-rating: uint,
    gigs-posted: uint
  }
)

(define-map client-reviews
  { review-id: uint }
  {
    client: principal,
    worker: principal,
    gig-id: uint,
    score: uint,
    communication-score: uint,
    payment-timeliness: uint,
    professionalism: uint,
    timestamp: uint,
    feedback: (string-ascii 256)
  }
)

(define-map gig-client-ratings
  { worker: principal, gig-id: uint }
  { rated: bool }
)

(define-public (register-client)
  (let ((client tx-sender))
    (if (is-some (get-client-profile client))
      err-client-already-exists
      (ok (map-set client-profiles
        { client: client }
        {
          total-score: u0,
          review-count: u0,
          average-rating: u0,
          gigs-posted: u0
        }
      ))
    )
  )
)

(define-public (rate-client (client principal) (gig-id uint) (score uint) (communication-score uint) (payment-timeliness uint) (professionalism uint) (feedback (string-ascii 256)))
  (let 
    (
      (review-id (+ (var-get client-review-counter) u1))
      (worker tx-sender)
      (gig-review (unwrap! (get-review gig-id) err-not-found))
    )
    (asserts! (and (>= score u1) (<= score u5)) err-invalid-score)
    (asserts! (and (>= communication-score u1) (<= communication-score u5)) err-invalid-score)
    (asserts! (and (>= payment-timeliness u1) (<= payment-timeliness u5)) err-invalid-score)
    (asserts! (and (>= professionalism u1) (<= professionalism u5)) err-invalid-score)
    (asserts! (is-eq worker (get worker gig-review)) err-unauthorized)
    (asserts! (is-eq client (get client gig-review)) err-unauthorized)
    (asserts! (is-none (map-get? gig-client-ratings { worker: worker, gig-id: gig-id })) err-already-rated-client)
    (unwrap-panic (update-client-stats client score))
    (var-set client-review-counter review-id)
    (map-set gig-client-ratings
      { worker: worker, gig-id: gig-id }
      { rated: true }
    )
    (ok (map-set client-reviews
      { review-id: review-id }
      {
        client: client,
        worker: worker,
        gig-id: gig-id,
        score: score,
        communication-score: communication-score,
        payment-timeliness: payment-timeliness,
        professionalism: professionalism,
        timestamp: burn-block-height,
        feedback: feedback
      }
    ))
  )
)

(define-private (update-client-stats (client principal) (new-score uint))
  (let
    (
      (profile (default-to 
        { total-score: u0, review-count: u0, average-rating: u0, gigs-posted: u0 }
        (get-client-profile client)
      ))
      (new-count (+ (get review-count profile) u1))
      (new-total (+ (get total-score profile) new-score))
      (new-average (/ new-total new-count))
    )
    (ok (map-set client-profiles
      { client: client }
      {
        total-score: new-total,
        review-count: new-count,
        average-rating: new-average,
        gigs-posted: (get gigs-posted profile)
      }
    ))
  )
)

(define-public (increment-client-gigs (client principal))
  (let 
    (
      (profile (default-to 
        { total-score: u0, review-count: u0, average-rating: u0, gigs-posted: u0 }
        (get-client-profile client)
      ))
    )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (ok (map-set client-profiles
      { client: client }
      (merge profile { gigs-posted: (+ (get gigs-posted profile) u1) })
    ))
  )
)

(define-read-only (get-client-profile (client principal))
  (map-get? client-profiles { client: client })
)

(define-read-only (get-client-review (review-id uint))
  (map-get? client-reviews { review-id: review-id })
)

(define-read-only (get-client-reputation (client principal))
  (let ((profile (unwrap! (get-client-profile client) err-client-not-found)))
    (ok {
      average-rating: (get average-rating profile),
      review-count: (get review-count profile),
      gigs-posted: (get gigs-posted profile)
    })
  )
)

(define-read-only (has-rated-client (worker principal) (gig-id uint))
  (is-some (map-get? gig-client-ratings { worker: worker, gig-id: gig-id }))
)
