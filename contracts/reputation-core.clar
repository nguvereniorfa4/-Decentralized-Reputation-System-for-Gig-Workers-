;; Decentralized Reputation System for Gig Workers - Core Contract
;; Clarity Version 2

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_WORKER_NOT_FOUND (err u101))
(define-constant ERR_INVALID_RATING (err u102))
(define-constant ERR_SELF_RATING (err u103))
(define-constant ERR_ALREADY_RATED (err u104))
(define-constant ERR_INSUFFICIENT_STAKE (err u105))
(define-constant ERR_DISPUTE_NOT_FOUND (err u106))
(define-constant ERR_DISPUTE_RESOLVED (err u107))
(define-constant MIN_STAKE u1000000) ;; 1 STX minimum stake
(define-constant MAX_RATING u5)
(define-constant MIN_RATING u1)

;; Data Variables
(define-data-var contract-owner principal tx-sender)
(define-data-var total-workers uint u0)
(define-data-var dispute-nonce uint u0)

;; Worker Profile Structure
(define-map worker-profiles
  { worker: principal }
  {
    name: (string-ascii 64),
    skills: (list 10 (string-ascii 32)),
    total-ratings: uint,
    total-score: uint,
    average-rating: uint,
    completed-gigs: uint,
    stake-amount: uint,
    registration-block: uint,
    is-active: bool
  }
)

;; Rating Records
(define-map ratings
  { rater: principal, worker: principal, gig-id: (string-ascii 64) }
  {
    rating: uint,
    comment: (string-ascii 256),
    block-height: uint,
    gig-category: (string-ascii 32)
  }
)

;; Dispute System
(define-map disputes
  { dispute-id: uint }
  {
    plaintiff: principal,
    defendant: principal,
    gig-id: (string-ascii 64),
    reason: (string-ascii 512),
    status: (string-ascii 16), ;; "pending", "resolved", "dismissed"
    resolution: (optional (string-ascii 512)),
    resolver: (optional principal),
    created-at: uint
  }
)

;; Worker Stakes (for dispute resolution)
(define-map worker-stakes
  { worker: principal }
  { amount: uint }
)

;; Helper Functions
(define-private (is-valid-rating (rating uint))
  (and (>= rating MIN_RATING) (<= rating MAX_RATING))
)

(define-private (calculate-average (total-score uint) (total-ratings uint))
  (if (> total-ratings u0)
    (/ total-score total-ratings)
    u0
  )
)

;; Public Functions

;; Register as a gig worker
(define-public (register-worker (name (string-ascii 64)) (skills (list 10 (string-ascii 32))))
  (begin
    (asserts! (is-none (map-get? worker-profiles { worker: tx-sender })) ERR_NOT_AUTHORIZED)
    (map-set worker-profiles
      { worker: tx-sender }
      {
        name: name,
        skills: skills,
        total-ratings: u0,
        total-score: u0,
        average-rating: u0,
        completed-gigs: u0,
        stake-amount: u0,
        registration-block: block-height,
        is-active: true
      }
    )
    (var-set total-workers (+ (var-get total-workers) u1))
    (ok true)
  )
)

;; Stake STX for dispute resolution eligibility
(define-public (stake-tokens (amount uint))
  (begin
    (asserts! (>= amount MIN_STAKE) ERR_INSUFFICIENT_STAKE)
    (asserts! (is-some (map-get? worker-profiles { worker: tx-sender })) ERR_WORKER_NOT_FOUND)
    
    ;; Transfer STX to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update stake record
    (map-set worker-stakes { worker: tx-sender } { amount: amount })
    
    ;; Update worker profile
    (match (map-get? worker-profiles { worker: tx-sender })
      profile (map-set worker-profiles
        { worker: tx-sender }
        (merge profile { stake-amount: (+ (get stake-amount profile) amount) })
      )
      ERR_WORKER_NOT_FOUND
    )
  )
)

;; Submit rating for a worker
(define-public (rate-worker (worker principal) (gig-id (string-ascii 64)) (rating uint) 
                          (comment (string-ascii 256)) (gig-category (string-ascii 32)))
  (let ((rating-key { rater: tx-sender, worker: worker, gig-id: gig-id }))
    (asserts! (not (is-eq tx-sender worker)) ERR_SELF_RATING)
    (asserts! (is-valid-rating rating) ERR_INVALID_RATING)
    (asserts! (is-some (map-get? worker-profiles { worker: worker })) ERR_WORKER_NOT_FOUND)
    (asserts! (is-none (map-get? ratings rating-key)) ERR_ALREADY_RATED)
    
    ;; Store the rating
    (map-set ratings rating-key {
      rating: rating,
      comment: comment,
      block-height: block-height,
      gig-category: gig-category
    })
    
    ;; Update worker profile stats
    (match (map-get? worker-profiles { worker: worker })
      profile (let ((new-total-ratings (+ (get total-ratings profile) u1))
                    (new-total-score (+ (get total-score profile) rating))
                    (new-average (calculate-average (+ (get total-score profile) rating) new-total-ratings)))
                (map-set worker-profiles { worker: worker }
                  (merge profile {
                    total-ratings: new-total-ratings,
                    total-score: new-total-score,
                    average-rating: new-average,
                    completed-gigs: (+ (get completed-gigs profile) u1)
                  })
                )
                (ok true)
              )
      ERR_WORKER_NOT_FOUND
    )
  )
)

;; File a dispute
(define-public (file-dispute (defendant principal) (gig-id (string-ascii 64)) (reason (string-ascii 512)))
  (let ((dispute-id (var-get dispute-nonce)))
    (asserts! (is-some (map-get? worker-profiles { worker: defendant })) ERR_WORKER_NOT_FOUND)
    
    (map-set disputes { dispute-id: dispute-id } {
      plaintiff: tx-sender,
      defendant: defendant,
      gig-id: gig-id,
      reason: reason,
      status: "pending",
      resolution: none,
      resolver: none,
      created-at: block-height
    })
    
    (var-set dispute-nonce (+ dispute-id u1))
    (ok dispute-id)
  )
)

;; Resolve dispute (only contract owner for now)
(define-public (resolve-dispute (dispute-id uint) (resolution (string-ascii 512)) (in-favor-of principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    
    (match (map-get? disputes { dispute-id: dispute-id })
      dispute (begin
                (asserts! (is-eq (get status dispute) "pending") ERR_DISPUTE_RESOLVED)
                (map-set disputes { dispute-id: dispute-id }
                  (merge dispute {
                    status: "resolved",
                    resolution: (some resolution),
                    resolver: (some tx-sender)
                  })
                )
                (ok true)
              )
      ERR_DISPUTE_NOT_FOUND
    )
  )
)

;; Update worker skills
(define-public (update-skills (new-skills (list 10 (string-ascii 32))))
  (match (map-get? worker-profiles { worker: tx-sender })
    profile (begin
              (map-set worker-profiles { worker: tx-sender }
                (merge profile { skills: new-skills })
              )
              (ok true)
            )
    ERR_WORKER_NOT_FOUND
  )
)

;; Deactivate worker profile
(define-public (deactivate-profile)
  (match (map-get? worker-profiles { worker: tx-sender })
    profile (begin
              (map-set worker-profiles { worker: tx-sender }
                (merge profile { is-active: false })
              )
              (ok true)
            )
    ERR_WORKER_NOT_FOUND
  )
)

;; Read-only functions

;; Get worker profile
(define-read-only (get-worker-profile (worker principal))
  (map-get? worker-profiles { worker: worker })
)

;; Get rating
(define-read-only (get-rating (rater principal) (worker principal) (gig-id (string-ascii 64)))
  (map-get? ratings { rater: rater, worker: worker, gig-id: gig-id })
)

;; Get dispute
(define-read-only (get-dispute (dispute-id uint))
  (map-get? disputes { dispute-id: dispute-id })
)

;; Get worker stake
(define-read-only (get-worker-stake (worker principal))
  (map-get? worker-stakes { worker: worker })
)

;; Get total workers count
(define-read-only (get-total-workers)
  (var-get total-workers)
)

;; Get contract stats
(define-read-only (get-contract-stats)
  {
    total-workers: (var-get total-workers),
    total-disputes: (var-get dispute-nonce),
    contract-owner: (var-get contract-owner)
  }
)
