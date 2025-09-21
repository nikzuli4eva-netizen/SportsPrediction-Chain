;; Prediction Market Engine Contract
;; Create and manage prediction markets for various sporting events and outcomes

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_MARKET_NOT_FOUND (err u201))
(define-constant ERR_INVALID_BET_AMOUNT (err u202))
(define-constant ERR_MARKET_CLOSED (err u203))
(define-constant ERR_MARKET_NOT_RESOLVED (err u204))
(define-constant ERR_ALREADY_CLAIMED (err u205))
(define-constant ERR_INSUFFICIENT_FUNDS (err u206))
(define-constant ERR_INVALID_OUTCOME (err u207))
(define-constant ERR_MARKET_ALREADY_RESOLVED (err u208))
(define-constant MIN_BET_AMOUNT u1000000) ;; 1 STX in microSTX
(define-constant PLATFORM_FEE_BASIS_POINTS u250) ;; 2.5%
(define-constant BASIS_POINTS u10000)

;; Data Variables
(define-data-var next-market-id uint u1)
(define-data-var next-bet-id uint u1)
(define-data-var platform-fee-rate uint PLATFORM_FEE_BASIS_POINTS)
(define-data-var total-platform-fees uint u0)
(define-data-var oracle-contract principal CONTRACT_OWNER)

;; Data Maps
(define-map prediction-markets
  { market-id: uint }
  {
    event-id: uint,
    name: (string-ascii 100),
    description: (string-ascii 200),
    creator: principal,
    creation-time: uint,
    betting-end-time: uint,
    resolution-time: (optional uint),
    is-resolved: bool,
    winning-outcome: (optional uint),
    total-pool: uint,
    platform-fees-collected: uint,
    outcome-count: uint
  }
)

(define-map market-outcomes
  { market-id: uint, outcome-id: uint }
  {
    description: (string-ascii 100),
    total-amount: uint,
    bet-count: uint,
    odds-numerator: uint,
    odds-denominator: uint
  }
)

(define-map user-bets
  { bet-id: uint }
  {
    market-id: uint,
    bettor: principal,
    outcome-id: uint,
    amount: uint,
    potential-payout: uint,
    bet-time: uint,
    is-claimed: bool
  }
)

(define-map user-market-bets
  { user: principal, market-id: uint }
  { bet-ids: (list 100 uint), total-amount: uint }
)

(define-map market-liquidity
  { market-id: uint }
  { 
    liquidity-providers: (list 50 principal),
    total-liquidity: uint,
    liquidity-shares: uint
  }
)

(define-map user-liquidity-positions
  { user: principal, market-id: uint }
  {
    amount-provided: uint,
    shares: uint,
    entry-time: uint
  }
)

;; Authorization Functions
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT_OWNER)
)

(define-private (is-oracle-contract (sender principal))
  (is-eq sender (var-get oracle-contract))
)

;; Public Functions

;; Create new prediction market
(define-public (create-market 
  (event-id uint)
  (name (string-ascii 100))
  (description (string-ascii 200))
  (betting-end-time uint)
  (outcomes (list 10 (string-ascii 100)))
)
  (let
    (
      (market-id (var-get next-market-id))
      (current-time u1000)
      (outcome-count (len outcomes))
    )
    (asserts! (> betting-end-time current-time) (err u209))
    (asserts! (<= outcome-count u10) (err u210))
    (asserts! (>= outcome-count u2) (err u211))
    
    (map-set prediction-markets
      { market-id: market-id }
      {
        event-id: event-id,
        name: name,
        description: description,
        creator: tx-sender,
        creation-time: current-time,
        betting-end-time: betting-end-time,
        resolution-time: none,
        is-resolved: false,
        winning-outcome: none,
        total-pool: u0,
        platform-fees-collected: u0,
        outcome-count: outcome-count
      }
    )
    
    ;; Create first two outcomes (simplified for validation)
    (map-set market-outcomes
      { market-id: market-id, outcome-id: u0 }
      {
        description: (default-to "Team A Wins" (element-at outcomes u0)),
        total-amount: u0,
        bet-count: u0,
        odds-numerator: u1,
        odds-denominator: u1
      }
    )
    (map-set market-outcomes
      { market-id: market-id, outcome-id: u1 }
      {
        description: (default-to "Team B Wins" (element-at outcomes u1)),
        total-amount: u0,
        bet-count: u0,
        odds-numerator: u1,
        odds-denominator: u1
      }
    )
    
    (var-set next-market-id (+ market-id u1))
    (ok market-id)
  )
)


;; Place bet on market outcome
(define-public (place-bet (market-id uint) (outcome-id uint) (amount uint))
  (let
    (
      (market (unwrap! (map-get? prediction-markets { market-id: market-id }) ERR_MARKET_NOT_FOUND))
      (outcome (unwrap! (map-get? market-outcomes { market-id: market-id, outcome-id: outcome-id }) ERR_INVALID_OUTCOME))
      (bet-id (var-get next-bet-id))
      (current-time u1000)
      (potential-payout (calculate-potential-payout market-id outcome-id amount))
    )
    (asserts! (>= amount MIN_BET_AMOUNT) ERR_INVALID_BET_AMOUNT)
    (asserts! (not (get is-resolved market)) ERR_MARKET_ALREADY_RESOLVED)
    (asserts! (<= current-time (get betting-end-time market)) ERR_MARKET_CLOSED)
    (asserts! (< outcome-id (get outcome-count market)) ERR_INVALID_OUTCOME)
    
    ;; Transfer STX from user to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Record the bet
    (map-set user-bets
      { bet-id: bet-id }
      {
        market-id: market-id,
        bettor: tx-sender,
        outcome-id: outcome-id,
        amount: amount,
        potential-payout: potential-payout,
        bet-time: current-time,
        is-claimed: false
      }
    )
    
    ;; Update user's market bets
    (try! (update-user-market-bets tx-sender market-id bet-id amount))
    
    ;; Update market totals
    (map-set prediction-markets
      { market-id: market-id }
      (merge market { total-pool: (+ (get total-pool market) amount) })
    )
    
    ;; Update outcome totals
    (map-set market-outcomes
      { market-id: market-id, outcome-id: outcome-id }
      (merge outcome {
        total-amount: (+ (get total-amount outcome) amount),
        bet-count: (+ (get bet-count outcome) u1)
      })
    )
    
    ;; Update odds
    (try! (update-market-odds market-id))
    
    (var-set next-bet-id (+ bet-id u1))
    (ok bet-id)
  )
)

;; Private helper to update user market bets
(define-private (update-user-market-bets (user principal) (market-id uint) (bet-id uint) (amount uint))
  (let
    (
      (current-bets (default-to { bet-ids: (list), total-amount: u0 }
                                 (map-get? user-market-bets { user: user, market-id: market-id })))
      (new-bet-ids (unwrap! (as-max-len? (append (get bet-ids current-bets) bet-id) u100) (err u212)))
    )
    (map-set user-market-bets
      { user: user, market-id: market-id }
      {
        bet-ids: new-bet-ids,
        total-amount: (+ (get total-amount current-bets) amount)
      }
    )
    (ok true)
  )
)

;; Calculate potential payout for a bet
(define-private (calculate-potential-payout (market-id uint) (outcome-id uint) (bet-amount uint))
  (let
    (
      (market (unwrap-panic (map-get? prediction-markets { market-id: market-id })))
      (outcome (unwrap-panic (map-get? market-outcomes { market-id: market-id, outcome-id: outcome-id })))
      (total-pool (get total-pool market))
      (outcome-total (get total-amount outcome))
      (adjusted-pool (if (> total-pool u0) total-pool u1))
    )
    (if (> outcome-total u0)
      ;; Calculate payout based on current pool distribution
      (/ (* bet-amount adjusted-pool) (+ outcome-total bet-amount))
      ;; First bet on this outcome
      (* bet-amount u2)
    )
  )
)

;; Update market odds based on current bets
(define-private (update-market-odds (market-id uint))
  (let
    (
      (market (unwrap! (map-get? prediction-markets { market-id: market-id }) ERR_MARKET_NOT_FOUND))
      (total-pool (get total-pool market))
    )
    ;; Update odds for each outcome
    (map update-outcome-odds-helper (list { market-id: market-id, outcome-id: u0 }
                                          { market-id: market-id, outcome-id: u1 }
                                          { market-id: market-id, outcome-id: u2 }
                                          { market-id: market-id, outcome-id: u3 }
                                          { market-id: market-id, outcome-id: u4 }))
    (ok true)
  )
)

;; Helper to update individual outcome odds
(define-private (update-outcome-odds-helper (params { market-id: uint, outcome-id: uint }))
  (let
    (
      (market-id (get market-id params))
      (outcome-id (get outcome-id params))
      (market (unwrap-panic (map-get? prediction-markets { market-id: market-id })))
      (outcome-result (map-get? market-outcomes { market-id: market-id, outcome-id: outcome-id }))
    )
    (match outcome-result
      outcome
      (let
        (
          (total-pool (get total-pool market))
          (outcome-amount (get total-amount outcome))
          (odds-num (if (> outcome-amount u0) total-pool outcome-amount))
          (odds-denom (if (> outcome-amount u0) outcome-amount u1))
        )
        (map-set market-outcomes
          { market-id: market-id, outcome-id: outcome-id }
          (merge outcome {
            odds-numerator: odds-num,
            odds-denominator: odds-denom
          })
        )
        true
      )
      false
    )
  )
)

;; Resolve market with winning outcome
(define-public (resolve-market (market-id uint) (winning-outcome uint))
  (let
    (
      (market (unwrap! (map-get? prediction-markets { market-id: market-id }) ERR_MARKET_NOT_FOUND))
      (current-time u1000)
    )
    ;; Only oracle contract or owner can resolve
    (asserts! (or (is-contract-owner) (is-oracle-contract tx-sender)) ERR_UNAUTHORIZED)
    (asserts! (not (get is-resolved market)) ERR_MARKET_ALREADY_RESOLVED)
    (asserts! (< winning-outcome (get outcome-count market)) ERR_INVALID_OUTCOME)
    (asserts! (>= current-time (get betting-end-time market)) ERR_MARKET_CLOSED)
    
    ;; Calculate platform fees
    (let
      (
        (total-pool (get total-pool market))
        (platform-fee (/ (* total-pool (var-get platform-fee-rate)) BASIS_POINTS))
      )
      
      (map-set prediction-markets
        { market-id: market-id }
        (merge market {
          is-resolved: true,
          winning-outcome: (some winning-outcome),
          resolution-time: (some current-time),
          platform-fees-collected: platform-fee
        })
      )
      
      ;; Update total platform fees
      (var-set total-platform-fees (+ (var-get total-platform-fees) platform-fee))
      
      (ok true)
    )
  )
)

;; Claim winnings from resolved market
(define-public (claim-winnings (bet-id uint))
  (let
    (
      (bet (unwrap! (map-get? user-bets { bet-id: bet-id }) (err u213)))
      (market (unwrap! (map-get? prediction-markets { market-id: (get market-id bet) }) ERR_MARKET_NOT_FOUND))
      (winning-outcome (unwrap! (get winning-outcome market) ERR_MARKET_NOT_RESOLVED))
    )
    (asserts! (is-eq (get bettor bet) tx-sender) ERR_UNAUTHORIZED)
    (asserts! (not (get is-claimed bet)) ERR_ALREADY_CLAIMED)
    (asserts! (get is-resolved market) ERR_MARKET_NOT_RESOLVED)
    
    (if (is-eq (get outcome-id bet) winning-outcome)
      ;; Calculate and transfer winnings
      (let
        (
          (payout (calculate-final-payout (get market-id bet) bet-id))
        )
        (try! (as-contract (stx-transfer? payout tx-sender (get bettor bet))))
        
        ;; Mark bet as claimed
        (map-set user-bets
          { bet-id: bet-id }
          (merge bet { is-claimed: true })
        )
        
        (ok payout)
      )
      ;; Losing bet - no payout
      (begin
        (map-set user-bets
          { bet-id: bet-id }
          (merge bet { is-claimed: true })
        )
        (ok u0)
      )
    )
  )
)

;; Calculate final payout for winning bet
(define-private (calculate-final-payout (market-id uint) (bet-id uint))
  (let
    (
      (market (unwrap-panic (map-get? prediction-markets { market-id: market-id })))
      (bet (unwrap-panic (map-get? user-bets { bet-id: bet-id })))
      (winning-outcome (unwrap-panic (get winning-outcome market)))
      (winning-outcome-data (unwrap-panic (map-get? market-outcomes { market-id: market-id, outcome-id: winning-outcome })))
      (total-pool (get total-pool market))
      (platform-fee (get platform-fees-collected market))
      (net-pool (- total-pool platform-fee))
      (winning-total (get total-amount winning-outcome-data))
      (bet-amount (get amount bet))
    )
    (if (> winning-total u0)
      ;; Proportional payout based on bet share of winning outcome
      (/ (* bet-amount net-pool) winning-total)
      bet-amount ;; Fallback
    )
  )
)

;; Provide liquidity to market
(define-public (provide-liquidity (market-id uint) (amount uint))
  (let
    (
      (market (unwrap! (map-get? prediction-markets { market-id: market-id }) ERR_MARKET_NOT_FOUND))
      (current-liquidity (default-to { liquidity-providers: (list), total-liquidity: u0, liquidity-shares: u0 }
                                     (map-get? market-liquidity { market-id: market-id })))
      (current-position (default-to { amount-provided: u0, shares: u0, entry-time: u0 }
                                   (map-get? user-liquidity-positions { user: tx-sender, market-id: market-id })))
      (current-time u1000)
      (shares-to-mint (if (> (get liquidity-shares current-liquidity) u0)
                        (/ (* amount (get liquidity-shares current-liquidity)) (get total-liquidity current-liquidity))
                        amount))
    )
    (asserts! (>= amount MIN_BET_AMOUNT) ERR_INVALID_BET_AMOUNT)
    (asserts! (not (get is-resolved market)) ERR_MARKET_ALREADY_RESOLVED)
    
    ;; Transfer STX from user to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update liquidity pool
    (map-set market-liquidity
      { market-id: market-id }
      {
        liquidity-providers: (get liquidity-providers current-liquidity),
        total-liquidity: (+ (get total-liquidity current-liquidity) amount),
        liquidity-shares: (+ (get liquidity-shares current-liquidity) shares-to-mint)
      }
    )
    
    ;; Update user position
    (map-set user-liquidity-positions
      { user: tx-sender, market-id: market-id }
      {
        amount-provided: (+ (get amount-provided current-position) amount),
        shares: (+ (get shares current-position) shares-to-mint),
        entry-time: current-time
      }
    )
    
    (ok shares-to-mint)
  )
)

;; Read-only functions

;; Get market information
(define-read-only (get-market (market-id uint))
  (map-get? prediction-markets { market-id: market-id })
)

;; Get market outcome
(define-read-only (get-market-outcome (market-id uint) (outcome-id uint))
  (map-get? market-outcomes { market-id: market-id, outcome-id: outcome-id })
)

;; Get user bet
(define-read-only (get-user-bet (bet-id uint))
  (map-get? user-bets { bet-id: bet-id })
)

;; Get user market bets
(define-read-only (get-user-market-bets (user principal) (market-id uint))
  (map-get? user-market-bets { user: user, market-id: market-id })
)

;; Calculate current odds
(define-read-only (calculate-odds (market-id uint) (outcome-id uint))
  (match (map-get? market-outcomes { market-id: market-id, outcome-id: outcome-id })
    outcome
    (ok {
      numerator: (get odds-numerator outcome),
      denominator: (get odds-denominator outcome)
    })
    ERR_INVALID_OUTCOME
  )
)

;; Admin functions
(define-public (set-oracle-contract (new-oracle principal))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (var-set oracle-contract new-oracle)
    (ok true)
  )
)

(define-public (withdraw-platform-fees (amount uint))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (asserts! (<= amount (var-get total-platform-fees)) ERR_INSUFFICIENT_FUNDS)
    
    (try! (as-contract (stx-transfer? amount tx-sender CONTRACT_OWNER)))
    (var-set total-platform-fees (- (var-get total-platform-fees) amount))
    
    (ok true)
  )
)

(define-public (set-platform-fee-rate (new-rate uint))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (asserts! (<= new-rate u1000) (err u214)) ;; Max 10%
    (var-set platform-fee-rate new-rate)
    (ok true)
  )
)

;; title: prediction-market-engine
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

