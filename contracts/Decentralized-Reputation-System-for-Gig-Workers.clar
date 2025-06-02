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
