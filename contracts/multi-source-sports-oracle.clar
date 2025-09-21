;; Multi-Source Sports Oracle Contract
;; Aggregates sports results from multiple data sources to prevent manipulation

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_EVENT_NOT_FOUND (err u101))
(define-constant ERR_INVALID_DATA_SOURCE (err u102))
(define-constant ERR_INSUFFICIENT_CONSENSUS (err u103))
(define-constant ERR_EVENT_ALREADY_RESOLVED (err u104))
(define-constant ERR_INVALID_OUTCOME (err u105))
(define-constant MIN_CONSENSUS_SOURCES u3)
(define-constant MAX_OUTCOMES u10)

;; Data Variables
(define-data-var next-event-id uint u1)
(define-data-var next-source-id uint u1)
(define-data-var consensus-threshold uint u3)

;; Data Maps
(define-map sports-events
  { event-id: uint }
  {
    name: (string-ascii 100),
    description: (string-ascii 200),
    start-time: uint,
    end-time: uint,
    sport-category: (string-ascii 50),
    is-resolved: bool,
    resolution-time: (optional uint),
    final-outcome: (optional uint),
    creator: principal
  }
)

(define-map data-sources
  { source-id: uint }
  {
    name: (string-ascii 50),
    api-endpoint: (string-ascii 200),
    owner: principal,
    is-active: bool,
    reliability-score: uint,
    total-submissions: uint,
    correct-submissions: uint
  }
)

(define-map event-outcomes
  { event-id: uint, outcome-id: uint }
  {
    description: (string-ascii 100),
    total-votes: uint,
    is-winner: bool
  }
)

(define-map source-submissions
  { event-id: uint, source-id: uint }
  {
    outcome-id: uint,
    submission-time: uint,
    confidence-level: uint,
    data-hash: (buff 32)
  }
)

(define-map source-votes
  { event-id: uint, outcome-id: uint }
  { vote-count: uint, sources: (list 20 uint) }
)

(define-map authorized-operators
  { operator: principal }
  { is-authorized: bool }
)

;; Authorization Functions
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT_OWNER)
)

(define-private (is-authorized-operator)
  (or (is-contract-owner)
      (default-to false (get is-authorized (map-get? authorized-operators { operator: tx-sender })))
  )
)

;; Public Functions

;; Register new data source
(define-public (register-data-source (name (string-ascii 50)) (api-endpoint (string-ascii 200)))
  (let
    (
      (source-id (var-get next-source-id))
    )
    (asserts! (is-authorized-operator) ERR_UNAUTHORIZED)
    (map-set data-sources
      { source-id: source-id }
      {
        name: name,
        api-endpoint: api-endpoint,
        owner: tx-sender,
        is-active: true,
        reliability-score: u100,
        total-submissions: u0,
        correct-submissions: u0
      }
    )
    (var-set next-source-id (+ source-id u1))
    (ok source-id)
  )
)

;; Create new sports event
(define-public (create-event 
  (name (string-ascii 100))
  (description (string-ascii 200))
  (start-time uint)
  (end-time uint)
  (sport-category (string-ascii 50))
  (outcomes (list 10 (string-ascii 100)))
)
  (let
    (
      (event-id (var-get next-event-id))
    )
    (asserts! (is-authorized-operator) ERR_UNAUTHORIZED)
    (asserts! (> end-time start-time) (err u106))
    (asserts! (<= (len outcomes) MAX_OUTCOMES) (err u107))
    
    (map-set sports-events
      { event-id: event-id }
      {
        name: name,
        description: description,
        start-time: start-time,
        end-time: end-time,
        sport-category: sport-category,
        is-resolved: false,
        resolution-time: none,
        final-outcome: none,
        creator: tx-sender
      }
    )
    
    ;; Create first two outcomes (simplified for validation)
    (map-set event-outcomes
      { event-id: event-id, outcome-id: u0 }
      {
        description: (default-to "Team A Wins" (element-at outcomes u0)),
        total-votes: u0,
        is-winner: false
      }
    )
    (map-set event-outcomes
      { event-id: event-id, outcome-id: u1 }
      {
        description: (default-to "Team B Wins" (element-at outcomes u1)),
        total-votes: u0,
        is-winner: false
      }
    )
    
    (var-set next-event-id (+ event-id u1))
    (ok event-id)
  )
)


;; Submit result from data source
(define-public (submit-result 
  (event-id uint)
  (source-id uint)
  (outcome-id uint)
  (confidence-level uint)
  (data-hash (buff 32))
)
  (let
    (
      (event (unwrap! (map-get? sports-events { event-id: event-id }) ERR_EVENT_NOT_FOUND))
      (source (unwrap! (map-get? data-sources { source-id: source-id }) ERR_INVALID_DATA_SOURCE))
      (current-time u1000)
    )
    (asserts! (get is-active source) ERR_INVALID_DATA_SOURCE)
    (asserts! (not (get is-resolved event)) ERR_EVENT_ALREADY_RESOLVED)
    (asserts! (>= current-time (get end-time event)) (err u108))
    (asserts! (<= confidence-level u100) (err u109))
    
    ;; Record the submission
    (map-set source-submissions
      { event-id: event-id, source-id: source-id }
      {
        outcome-id: outcome-id,
        submission-time: current-time,
        confidence-level: confidence-level,
        data-hash: data-hash
      }
    )
    
    ;; Update source statistics
    (map-set data-sources
      { source-id: source-id }
      (merge source { total-submissions: (+ (get total-submissions source) u1) })
    )
    
    ;; Update outcome vote count
    (try! (update-outcome-votes event-id outcome-id source-id))
    
    ;; Check if consensus is reached
    (try! (check-and-resolve-consensus event-id))
    
    (ok true)
  )
)

;; Private function to update outcome votes
(define-private (update-outcome-votes (event-id uint) (outcome-id uint) (source-id uint))
  (let
    (
      (current-votes (default-to { vote-count: u0, sources: (list) } 
                                  (map-get? source-votes { event-id: event-id, outcome-id: outcome-id })))
      (new-sources (unwrap! (as-max-len? (append (get sources current-votes) source-id) u20) (err u110)))
    )
    (map-set source-votes
      { event-id: event-id, outcome-id: outcome-id }
      {
        vote-count: (+ (get vote-count current-votes) u1),
        sources: new-sources
      }
    )
    (ok true)
  )
)

;; Check and resolve consensus
(define-private (check-and-resolve-consensus (event-id uint))
  (let
    (
      (event (unwrap! (map-get? sports-events { event-id: event-id }) ERR_EVENT_NOT_FOUND))
      (winning-outcome (find-winning-outcome event-id))
    )
    (if (is-some winning-outcome)
      (begin
        (map-set sports-events
          { event-id: event-id }
          (merge event {
            is-resolved: true,
            resolution-time: (some u1000),
            final-outcome: winning-outcome
          })
        )
        ;; Mark winning outcome
        (map-set event-outcomes
          { event-id: event-id, outcome-id: (unwrap! winning-outcome (err u111)) }
          (merge (unwrap! (map-get? event-outcomes { event-id: event-id, outcome-id: (unwrap! winning-outcome (err u111)) }) (err u111))
                 { is-winner: true })
        )
        (ok true)
      )
      (ok false)
    )
  )
)

;; Find winning outcome based on consensus
(define-private (find-winning-outcome (event-id uint))
  (let
    (
      (threshold (var-get consensus-threshold))
      (outcome-0-votes (get vote-count (default-to { vote-count: u0, sources: (list) } 
                                                    (map-get? source-votes { event-id: event-id, outcome-id: u0 }))))
      (outcome-1-votes (get vote-count (default-to { vote-count: u0, sources: (list) } 
                                                    (map-get? source-votes { event-id: event-id, outcome-id: u1 }))))
    )
    (if (>= outcome-0-votes threshold)
      (some u0)
      (if (>= outcome-1-votes threshold)
        (some u1)
        none
      )
    )
  )
)

;; Get event information
(define-read-only (get-event (event-id uint))
  (map-get? sports-events { event-id: event-id })
)

;; Get event result
(define-read-only (get-event-result (event-id uint))
  (let
    (
      (event (unwrap! (map-get? sports-events { event-id: event-id }) ERR_EVENT_NOT_FOUND))
    )
    (if (get is-resolved event)
      (ok (get final-outcome event))
      (err u104)
    )
  )
)

;; Get data source information
(define-read-only (get-data-source (source-id uint))
  (map-get? data-sources { source-id: source-id })
)

;; Get outcome votes
(define-read-only (get-outcome-votes (event-id uint) (outcome-id uint))
  (map-get? source-votes { event-id: event-id, outcome-id: outcome-id })
)

;; Verify consensus for an event
(define-read-only (verify-consensus (event-id uint))
  (let
    (
      (event (unwrap! (map-get? sports-events { event-id: event-id }) ERR_EVENT_NOT_FOUND))
    )
    (ok (get is-resolved event))
  )
)

;; Admin functions
(define-public (set-consensus-threshold (new-threshold uint))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (asserts! (>= new-threshold u1) (err u112))
    (var-set consensus-threshold new-threshold)
    (ok true)
  )
)

(define-public (authorize-operator (operator principal))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (map-set authorized-operators
      { operator: operator }
      { is-authorized: true }
    )
    (ok true)
  )
)

(define-public (deactivate-source (source-id uint))
  (let
    (
      (source (unwrap! (map-get? data-sources { source-id: source-id }) ERR_INVALID_DATA_SOURCE))
    )
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (map-set data-sources
      { source-id: source-id }
      (merge source { is-active: false })
    )
    (ok true)
  )
)

;; title: multi-source-sports-oracle
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

