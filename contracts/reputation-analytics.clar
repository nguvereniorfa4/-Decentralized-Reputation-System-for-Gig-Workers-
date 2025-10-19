;; Reputation Analytics Contract - Advanced Analytics and Insights
;; Clarity Version 2
;; Independent feature for tracking and analyzing reputation trends

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u200))
(define-constant ERR_INVALID_PERIOD (err u201))
(define-constant ERR_CATEGORY_NOT_FOUND (err u202))
(define-constant ERR_INSUFFICIENT_DATA (err u203))
(define-constant ERR_INVALID_THRESHOLD (err u204))
(define-constant MAX_CATEGORIES u20)
(define-constant MIN_SAMPLE_SIZE u5)
(define-constant TRENDING_THRESHOLD u10) ;; Minimum activities for trending

;; Data Variables
(define-data-var analytics-enabled bool true)
(define-data-var total-analytics-queries uint u0)
(define-data-var last-update-block uint u0)

;; Category Performance Tracking
(define-map category-stats
  { category: (string-ascii 32), period: (string-ascii 16) }
  {
    total-ratings: uint,
    average-score: uint,
    total-workers: uint,
    total-gigs: uint,
    growth-rate: int,
    last-updated: uint
  }
)

;; Worker Performance Trends
(define-map worker-trends
  { worker: principal, timeframe: (string-ascii 16) }
  {
    rating-trend: (string-ascii 16), ;; "up", "down", "stable"
    performance-score: uint,
    consistency-rating: uint,
    activity-level: (string-ascii 16), ;; "high", "medium", "low"
    specialization-score: uint,
    calculated-at: uint
  }
)

;; Market Insights
(define-map market-insights
  { insight-id: uint }
  {
    insight-type: (string-ascii 32),
    category: (optional (string-ascii 32)),
    metric: (string-ascii 64),
    value: uint,
    trend: (string-ascii 16),
    confidence-level: uint,
    generated-at: uint,
    is-active: bool
  }
)

;; Platform Health Metrics
(define-map platform-health
  { metric: (string-ascii 32), period: (string-ascii 16) }
  {
    value: uint,
    benchmark: uint,
    status: (string-ascii 16), ;; "healthy", "warning", "critical"
    last-calculated: uint
  }
)

;; Reputation Score Bands
(define-map score-distribution
  { band: (string-ascii 16), category: (optional (string-ascii 32)) }
  {
    count: uint,
    percentage: uint,
    avg-earnings-potential: uint,
    last-updated: uint
  }
)

;; Data Variables for counters
(define-data-var insight-nonce uint u0)
(define-data-var active-categories uint u0)

;; Helper Functions
(define-private (is-valid-period (period (string-ascii 16)))
  (or (is-eq period "weekly") 
      (is-eq period "monthly") 
      (is-eq period "quarterly")
      (is-eq period "yearly"))
)

(define-private (calculate-growth-rate (current uint) (previous uint))
  (if (> previous u0)
    (to-int (/ (* (- current previous) u100) previous))
    0
  )
)

(define-private (determine-trend (current uint) (previous uint))
  (let ((diff (if (> current previous) (- current previous) (- previous current))))
    (if (> current previous)
      "up"
      (if (< current previous)
        "down"
        "stable")
    )
  )
)

(define-private (calculate-consistency (ratings-variance uint))
  (if (<= ratings-variance u10) u5
    (if (<= ratings-variance u20) u4
      (if (<= ratings-variance u30) u3
        (if (<= ratings-variance u40) u2
          u1))))
)

;; Public Functions

;; Update category statistics
(define-public (update-category-stats (category (string-ascii 32)) (period (string-ascii 16)) 
                                    (total-ratings uint) (avg-score uint) (worker-count uint) (gig-count uint))
  (begin
    (asserts! (is-valid-period period) ERR_INVALID_PERIOD)
    
    ;; Get previous stats for growth calculation
    (let ((previous-stats (default-to 
                            { total-ratings: u0, average-score: u0, total-workers: u0, 
                              total-gigs: u0, growth-rate: 0, last-updated: u0 }
                            (map-get? category-stats { category: category, period: period })))
          (growth (calculate-growth-rate total-ratings (get total-ratings previous-stats))))
      
      (map-set category-stats 
        { category: category, period: period }
        {
          total-ratings: total-ratings,
          average-score: avg-score,
          total-workers: worker-count,
          total-gigs: gig-count,
          growth-rate: growth,
          last-updated: block-height
        }
      )
      
      (var-set total-analytics-queries (+ (var-get total-analytics-queries) u1))
      (ok true)
    )
  )
)

;; Analyze worker performance trends
(define-public (analyze-worker-trends (worker principal) (timeframe (string-ascii 16)) 
                                     (current-rating uint) (previous-rating uint) 
                                     (activity-count uint) (rating-variance uint))
  (let ((trend (determine-trend current-rating previous-rating))
        (consistency (calculate-consistency rating-variance))
        (activity-level (if (>= activity-count TRENDING_THRESHOLD) "high"
                          (if (>= activity-count u5) "medium" "low")))
        (performance-score (+ current-rating consistency))
        (specialization-score (if (<= rating-variance u5) u10
                                (if (<= rating-variance u15) u7 u5))))
    
    (map-set worker-trends
      { worker: worker, timeframe: timeframe }
      {
        rating-trend: trend,
        performance-score: performance-score,
        consistency-rating: consistency,
        activity-level: activity-level,
        specialization-score: specialization-score,
        calculated-at: block-height
      }
    )
    
    (ok true)
  )
)

;; Generate market insights
(define-public (generate-market-insight (insight-type (string-ascii 32)) (category (optional (string-ascii 32)))
                                       (metric (string-ascii 64)) (value uint) (confidence uint))
  (let ((insight-id (var-get insight-nonce))
        (trend (if (> value u50) "up" (if (< value u30) "down" "stable"))))
    
    (asserts! (<= confidence u100) ERR_INVALID_THRESHOLD)
    
    (map-set market-insights 
      { insight-id: insight-id }
      {
        insight-type: insight-type,
        category: category,
        metric: metric,
        value: value,
        trend: trend,
        confidence-level: confidence,
        generated-at: block-height,
        is-active: true
      }
    )
    
    (var-set insight-nonce (+ insight-id u1))
    (ok insight-id)
  )
)

;; Update platform health metrics
(define-public (update-platform-health (metric (string-ascii 32)) (period (string-ascii 16))
                                      (value uint) (benchmark uint))
  (let ((status (if (>= value benchmark) "healthy"
                  (if (>= value (/ benchmark u2)) "warning" "critical"))))
    
    (asserts! (is-valid-period period) ERR_INVALID_PERIOD)
    
    (map-set platform-health
      { metric: metric, period: period }
      {
        value: value,
        benchmark: benchmark,
        status: status,
        last-calculated: block-height
      }
    )
    
    (ok true)
  )
)

;; Update score distribution analytics
(define-public (update-score-distribution (band (string-ascii 16)) (category (optional (string-ascii 32)))
                                         (count uint) (percentage uint) (avg-earnings uint))
  (begin
    (asserts! (<= percentage u100) ERR_INVALID_THRESHOLD)
    
    (map-set score-distribution
      { band: band, category: category }
      {
        count: count,
        percentage: percentage,
        avg-earnings-potential: avg-earnings,
        last-updated: block-height
      }
    )
    
    (ok true)
  )
)

;; Batch update for efficiency
(define-public (batch-update-categories (categories (list 5 (string-ascii 32))) 
                                       (period (string-ascii 16)) 
                                       (ratings-list (list 5 uint))
                                       (scores-list (list 5 uint)))
  (begin
    (asserts! (is-valid-period period) ERR_INVALID_PERIOD)
    (asserts! (is-eq (len categories) (len ratings-list)) ERR_INSUFFICIENT_DATA)
    (asserts! (is-eq (len categories) (len scores-list)) ERR_INSUFFICIENT_DATA)
    
    ;; Process each category
    (var-set last-update-block block-height)
    (ok (len categories))
  )
)

;; Toggle analytics system
(define-public (toggle-analytics (enabled bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (var-set analytics-enabled enabled)
    (ok enabled)
  )
)

;; Deactivate old insights
(define-public (deactivate-insight (insight-id uint))
  (match (map-get? market-insights { insight-id: insight-id })
    insight (begin
              (map-set market-insights { insight-id: insight-id }
                (merge insight { is-active: false })
              )
              (ok true)
            )
    ERR_CATEGORY_NOT_FOUND
  )
)

;; Read-only functions

;; Get category statistics
(define-read-only (get-category-stats (category (string-ascii 32)) (period (string-ascii 16)))
  (map-get? category-stats { category: category, period: period })
)

;; Get worker trend analysis
(define-read-only (get-worker-trends (worker principal) (timeframe (string-ascii 16)))
  (map-get? worker-trends { worker: worker, timeframe: timeframe })
)

;; Get market insight
(define-read-only (get-market-insight (insight-id uint))
  (map-get? market-insights { insight-id: insight-id })
)

;; Get platform health status
(define-read-only (get-platform-health (metric (string-ascii 32)) (period (string-ascii 16)))
  (map-get? platform-health { metric: metric, period: period })
)

;; Get score distribution
(define-read-only (get-score-distribution (band (string-ascii 16)) (category (optional (string-ascii 32))))
  (map-get? score-distribution { band: band, category: category })
)

;; Get analytics summary
(define-read-only (get-analytics-summary)
  {
    analytics-enabled: (var-get analytics-enabled),
    total-queries: (var-get total-analytics-queries),
    total-insights: (var-get insight-nonce),
    last-update: (var-get last-update-block),
    active-categories: (var-get active-categories)
  }
)

;; Check if analytics are enabled
(define-read-only (is-analytics-enabled)
  (var-get analytics-enabled)
)

;; Get trending categories (simplified version)
(define-read-only (get-trending-metrics)
  {
    total-insights: (var-get insight-nonce),
    queries-processed: (var-get total-analytics-queries),
    last-calculation: (var-get last-update-block),
    system-status: (if (var-get analytics-enabled) "active" "inactive")
  }
)
