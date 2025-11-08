;; Title: CryptoVault DeFi Lending Protocol
;;
;; Streamlined decentralized lending with crypto-backed loans,
;; automated liquidations, and dynamic risk management.

;; TRAIT IMPORTS
(use-trait ft-trait 'SP3FBR2AGK5H9QBDH3EEN6DF8EK8JY7RX8QJ5SVTE.sip-010-trait-ft-standard.sip-010-trait)

;; CONSTANTS
(define-constant CONTRACT-OWNER tx-sender)
(define-constant PROTOCOL-WALLET (as-contract tx-sender))

;; Error Codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u101))
(define-constant ERR-INVALID-AMOUNT (err u103))
(define-constant ERR-NOT-INITIALIZED (err u105))
(define-constant ERR-LOAN-NOT-FOUND (err u107))
(define-constant ERR-LOAN-NOT-ACTIVE (err u108))
(define-constant ERR-INVALID-PRICE (err u110))
(define-constant ERR-INVALID-ASSET (err u111))
(define-constant ERR-PAUSED (err u112))
(define-constant ERR-LIQUIDATION-NOT-TRIGGERED (err u113))
(define-constant ERR-PRICE-TOO-OLD (err u118))

;; Protocol Parameters
(define-constant BLOCKS-PER-DAY u144)
(define-constant MAX-PRICE-AGE u1440)
(define-constant LIQUIDATION-BONUS u10)
(define-constant MAX-INTEREST-RATE u50)

;; STATE VARIABLES
(define-data-var platform-initialized bool false)
(define-data-var platform-paused bool false)
(define-data-var minimum-collateral-ratio uint u150)
(define-data-var liquidation-threshold uint u125)
(define-data-var total-collateral-locked uint u0)
(define-data-var total-loans-issued uint u0)
(define-data-var total-value-liquidated uint u0)

;; DATA MAPS
(define-map loans
  { loan-id: uint }
  {
    borrower: principal,
    collateral-token: principal,
    loan-token: principal,
    collateral-amount: uint,
    loan-amount: uint,
    outstanding-amount: uint,
    interest-rate: uint,
    start-height: uint,
    last-interest-calc: uint,
    status: (string-ascii 20),
  }
)

(define-map user-loans
  { user: principal }
  { active-loans: (list 100 uint) }
)

(define-map collateral-prices
  { asset: principal }
  { 
    price: uint,
    last-update: uint,
  }
)

(define-map whitelisted-tokens
  { token: principal }
  { enabled: bool }
)

;; CALCULATION FUNCTIONS
(define-private (calculate-collateral-ratio
    (collateral uint)
    (loan uint)
    (collateral-price uint)
  )
  (if (is-eq loan u0)
    ERR-INVALID-AMOUNT
    (ok (/ (* (* collateral collateral-price) u100) loan))
  )
)

(define-private (calculate-interest
    (principal-amount uint)
    (rate uint)
    (blocks uint)
  )
  (let (
      (rate-per-block (/ rate (* u100 BLOCKS-PER-DAY u365)))
      (interest (/ (* (* principal-amount rate-per-block) blocks) u100))
    )
    (if (> rate MAX-INTEREST-RATE)
      ERR-INVALID-AMOUNT
      (ok interest)
    )
  )
)

;; VALIDATION FUNCTIONS
(define-private (check-not-paused)
  (ok (asserts! (not (var-get platform-paused)) ERR-PAUSED))
)

(define-private (is-whitelisted-token (token principal))
  (default-to false (get enabled (map-get? whitelisted-tokens { token: token })))
)

(define-private (is-price-fresh (token principal))
  (match (map-get? collateral-prices { asset: token })
    price-data 
      (<= (- stacks-block-height (get last-update price-data)) MAX-PRICE-AGE)
    false
  )
)

(define-private (check-liquidation-eligibility (loan-id uint))
  (let (
      (loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR-LOAN-NOT-FOUND))
      (price-data (unwrap! (map-get? collateral-prices { asset: (get collateral-token loan) })
        ERR-NOT-INITIALIZED))
      (collateral-price (get price price-data))
      (current-ratio (try! (calculate-collateral-ratio 
        (get collateral-amount loan)
        (get outstanding-amount loan)
        collateral-price)))
    )
    (ok (<= current-ratio (var-get liquidation-threshold)))
  )
)

;; CORE FUNCTIONS
(define-public (initialize-platform)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (not (var-get platform-initialized)) ERR-NOT-INITIALIZED)
    (var-set platform-initialized true)
    (ok true)
  )
)

(define-public (set-pause (paused bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set platform-paused paused)
    (ok true)
  )
)

(define-public (whitelist-token (token principal) (enabled bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (map-set whitelisted-tokens { token: token } { enabled: enabled })
    (ok true)
  )
)

(define-public (request-loan
    (collateral-amount uint)
    (loan-amount uint)
    (collateral-token <ft-trait>)
    (loan-token <ft-trait>)
    (interest-rate uint)
  )
  (let (
      (collateral-principal (contract-of collateral-token))
      (loan-principal (contract-of loan-token))
      (price-data (unwrap! (map-get? collateral-prices { asset: collateral-principal })
        ERR-NOT-INITIALIZED))
      (collateral-price (get price price-data))
      (collateral-value (/ (* collateral-amount collateral-price) u100))
      (required-collateral (* loan-amount (var-get minimum-collateral-ratio)))
      (loan-id (+ (var-get total-loans-issued) u1))
    )
    (begin
      (try! (check-not-paused))
      (asserts! (var-get platform-initialized) ERR-NOT-INITIALIZED)
      (asserts! (is-whitelisted-token collateral-principal) ERR-INVALID-ASSET)
      (asserts! (is-whitelisted-token loan-principal) ERR-INVALID-ASSET)
      (asserts! (is-price-fresh collateral-principal) ERR-PRICE-TOO-OLD)
      (asserts! (<= interest-rate MAX-INTEREST-RATE) ERR-INVALID-AMOUNT)
      (asserts! (>= collateral-value required-collateral) ERR-INSUFFICIENT-COLLATERAL)
      
      ;; Transfer collateral from borrower to protocol
      (try! (contract-call? collateral-token transfer 
        collateral-amount 
        tx-sender 
        PROTOCOL-WALLET
        none))
      
      ;; Disburse loan amount to borrower
      (try! (as-contract (contract-call? loan-token transfer 
        loan-amount 
        PROTOCOL-WALLET
        tx-sender
        none)))
      
      ;; Create loan record
      (map-set loans { loan-id: loan-id } {
        borrower: tx-sender,
        collateral-token: collateral-principal,
        loan-token: loan-principal,
        collateral-amount: collateral-amount,
        loan-amount: loan-amount,
        outstanding-amount: loan-amount,
        interest-rate: interest-rate,
        start-height: stacks-block-height,
        last-interest-calc: stacks-block-height,
        status: "active",
      })
      
      ;; Update user's loan portfolio
      (match (map-get? user-loans { user: tx-sender })
        existing-loans 
          (map-set user-loans { user: tx-sender } 
            { active-loans: (unwrap! 
              (as-max-len? (append (get active-loans existing-loans) loan-id) u100)
              ERR-INVALID-AMOUNT) })
        (map-set user-loans { user: tx-sender } { active-loans: (list loan-id) })
      )
      
      (var-set total-loans-issued loan-id)
      (var-set total-collateral-locked 
        (+ (var-get total-collateral-locked) collateral-amount))
      (ok loan-id)
    )
  )
)

(define-public (repay-loan
    (loan-id uint)
    (amount uint)
    (loan-token <ft-trait>)
  )
  (let (
      (loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR-LOAN-NOT-FOUND))
      (loan-principal (contract-of loan-token))
      (blocks-elapsed (- stacks-block-height (get last-interest-calc loan)))
      (interest-owed (try! (calculate-interest 
        (get outstanding-amount loan) 
        (get interest-rate loan)
        blocks-elapsed)))
      (total-owed (+ (get outstanding-amount loan) interest-owed))
      (is-full-repayment (>= amount total-owed))
    )
    (begin
      (try! (check-not-paused))
      (asserts! (is-eq (get status loan) "active") ERR-LOAN-NOT-ACTIVE)
      (asserts! (is-eq (get borrower loan) tx-sender) ERR-NOT-AUTHORIZED)
      (asserts! (is-eq (get loan-token loan) loan-principal) ERR-INVALID-ASSET)
      (asserts! (> amount u0) ERR-INVALID-AMOUNT)
      
      ;; Transfer repayment from borrower to protocol
      (try! (contract-call? loan-token transfer 
        amount 
        tx-sender 
        PROTOCOL-WALLET
        none))
      
      (if is-full-repayment
        (begin
          (map-set loans { loan-id: loan-id }
            (merge loan {
              status: "repaid",
              outstanding-amount: u0,
              last-interest-calc: stacks-block-height,
            }))
          
          (var-set total-collateral-locked
            (- (var-get total-collateral-locked) (get collateral-amount loan)))
          
          (ok { repaid: total-owed, remaining: u0 })
        )
        (begin
          (let ((new-outstanding (- total-owed amount)))
            (map-set loans { loan-id: loan-id }
              (merge loan {
                outstanding-amount: new-outstanding,
                last-interest-calc: stacks-block-height,
              }))
            (ok { repaid: amount, remaining: new-outstanding })
          )
        )
      )
    )
  )
)

(define-public (liquidate-loan 
    (loan-id uint)
    (collateral-token <ft-trait>)
    (loan-token <ft-trait>)
  )
  (let (
      (loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR-LOAN-NOT-FOUND))
      (collateral-principal (contract-of collateral-token))
      (loan-principal (contract-of loan-token))
      (is-liquidatable (try! (check-liquidation-eligibility loan-id)))
      (blocks-elapsed (- stacks-block-height (get last-interest-calc loan)))
      (interest-owed (try! (calculate-interest 
        (get outstanding-amount loan)
        (get interest-rate loan)
        blocks-elapsed)))
      (total-debt (+ (get outstanding-amount loan) interest-owed))
      (liquidation-bonus-amount (/ (* (get collateral-amount loan) LIQUIDATION-BONUS) u100))
      (liquidator-reward (+ (get collateral-amount loan) liquidation-bonus-amount))
    )
    (begin
      (try! (check-not-paused))
      (asserts! (is-eq (get status loan) "active") ERR-LOAN-NOT-ACTIVE)
      (asserts! is-liquidatable ERR-LIQUIDATION-NOT-TRIGGERED)
      (asserts! (is-eq (get collateral-token loan) collateral-principal) ERR-INVALID-ASSET)
      (asserts! (is-eq (get loan-token loan) loan-principal) ERR-INVALID-ASSET)
      
      ;; Liquidator pays off the debt
      (try! (contract-call? loan-token transfer 
        total-debt 
        tx-sender 
        PROTOCOL-WALLET
        none))
      
      ;; Transfer collateral + bonus to liquidator
      (try! (as-contract (contract-call? collateral-token transfer 
        liquidator-reward
        PROTOCOL-WALLET
        tx-sender
        none)))
      
      ;; Update loan status
      (map-set loans { loan-id: loan-id }
        (merge loan {
          status: "liquidated",
          last-interest-calc: stacks-block-height,
        }))
      
      (var-set total-value-liquidated 
        (+ (var-get total-value-liquidated) total-debt))
      (var-set total-collateral-locked
        (- (var-get total-collateral-locked) (get collateral-amount loan)))
      
      (ok { debt-paid: total-debt, collateral-seized: liquidator-reward })
    )
  )
)

;; GOVERNANCE FUNCTIONS
(define-public (update-collateral-ratio (new-ratio uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (>= new-ratio u110) ERR-INVALID-AMOUNT)
    (asserts! (<= new-ratio u300) ERR-INVALID-AMOUNT)
    (var-set minimum-collateral-ratio new-ratio)
    (ok true)
  )
)

(define-public (update-liquidation-threshold (new-threshold uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (>= new-threshold u110) ERR-INVALID-AMOUNT)
    (asserts! (< new-threshold (var-get minimum-collateral-ratio)) ERR-INVALID-AMOUNT)
    (var-set liquidation-threshold new-threshold)
    (ok true)
  )
)

(define-public (update-price-feed
    (asset principal)
    (new-price uint)
  )
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-whitelisted-token asset) ERR-INVALID-ASSET)
    (asserts! (> new-price u0) ERR-INVALID-PRICE)
    
    (ok (map-set collateral-prices 
      { asset: asset } 
      { price: new-price, last-update: stacks-block-height }))
  )
)

;; READ-ONLY FUNCTIONS
(define-read-only (get-loan-details (loan-id uint))
  (map-get? loans { loan-id: loan-id })
)

(define-read-only (get-current-debt (loan-id uint))
  (match (map-get? loans { loan-id: loan-id })
    loan
      (let (
          (blocks-elapsed (- stacks-block-height (get last-interest-calc loan)))
          (interest (unwrap! (calculate-interest 
            (get outstanding-amount loan)
            (get interest-rate loan)
            blocks-elapsed) (err u0)))
        )
        (ok {
          principal: (get outstanding-amount loan),
          interest: interest,
          total: (+ (get outstanding-amount loan) interest)
        }))
    ERR-LOAN-NOT-FOUND)
)

(define-read-only (get-user-loans (user principal))
  (map-get? user-loans { user: user })
)

(define-read-only (get-loan-health (loan-id uint))
  (match (map-get? loans { loan-id: loan-id })
    loan
      (match (map-get? collateral-prices { asset: (get collateral-token loan) })
        price-data
          (let (
              (current-ratio (unwrap! (calculate-collateral-ratio
                (get collateral-amount loan)
                (get outstanding-amount loan)
                (get price price-data)) (err u0)))
              (liquidation-thresh (var-get liquidation-threshold))
            )
            (ok {
              collateral-ratio: current-ratio,
              liquidation-threshold: liquidation-thresh,
              is-healthy: (> current-ratio liquidation-thresh),
              can-liquidate: (<= current-ratio liquidation-thresh)
            }))
        ERR-NOT-INITIALIZED)
    ERR-LOAN-NOT-FOUND)
)

(define-read-only (get-platform-stats)
  {
    total-collateral-locked: (var-get total-collateral-locked),
    total-loans-issued: (var-get total-loans-issued),
    total-value-liquidated: (var-get total-value-liquidated),
    minimum-collateral-ratio: (var-get minimum-collateral-ratio),
    liquidation-threshold: (var-get liquidation-threshold),
    platform-paused: (var-get platform-paused),
  }
)

(define-read-only (get-token-price (token principal))
  (map-get? collateral-prices { asset: token })
)

(define-read-only (is-token-whitelisted (token principal))
  (is-whitelisted-token token)
)