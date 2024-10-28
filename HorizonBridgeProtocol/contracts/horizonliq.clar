;; Cross-Chain Liquidity Bridge Contract
;; Implements secure cross-chain token transfers with AMM functionality

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-insufficient-balance (err u101))
(define-constant err-invalid-amount (err u102))
(define-constant err-bridge-paused (err u103))
(define-constant err-slippage-exceeded (err u104))
(define-constant err-invalid-pool (err u105))
(define-constant err-invalid-recipient (err u106))
(define-constant err-invalid-chain (err u107))
(define-constant err-invalid-transfer-id (err u108))
(define-constant err-invalid-price (err u109))
(define-constant err-invalid-fee-rate (err u110))

;; Constants for validation
(define-constant max-fee-rate uint u1000) ;; 10% max fee
(define-constant max-price uint u100000000000) ;; Maximum reasonable price
(define-constant valid-chains (list u"ethereum" u"bitcoin" u"bsc" u"polygon"))

;; Data Variables
(define-data-var bridge-paused bool false)
(define-data-var min-transfer-amount uint u100000) ;; in micro units
(define-data-var max-transfer-amount uint u1000000000000) ;; in micro units
(define-data-var bridge-fee-rate uint u25) ;; 0.25% = 25 basis points
(define-data-var oracle-price uint u1000000) ;; price with 6 decimal places
(define-data-var transfer-nonce uint u0)

;; Data Maps
(define-map liquidity-pools
    principal
    {
        balance: uint,
        total-supplied: uint,
        last-update-block: uint
    }
)
(define-map pending-transfers
    uint
    {
        sender: principal,
        recipient: principal,
        amount: uint,
        target-chain: (string-utf8 32),
        status: (string-utf8 10)
    }
)
(define-map user-balances principal uint)

;; Validation functions
(define-private (is-valid-chain (chain (string-utf8 32)))
    (is-some (index-of valid-chains chain))
)

(define-private (is-valid-recipient (address principal))
    (and 
        (not (is-eq address contract-owner))
        (not (is-eq address (as-contract tx-sender)))
    )
)

(define-private (is-valid-transfer-id (id uint))
    (and
        (< id (var-get transfer-nonce))
        (is-some (map-get? pending-transfers id))
    )
)

;; Public Functions

;; Add liquidity to the pool
(define-public (add-liquidity (amount uint))
    (let (
        (sender tx-sender)
        (current-balance (default-to u0 (map-get? user-balances sender)))
    )
    (asserts! (>= current-balance amount) err-insufficient-balance)
    (asserts! (not (var-get bridge-paused)) err-bridge-paused)

    ;; Update pool balance
    (map-set liquidity-pools 
        sender
        {
            balance: (+ (get-pool-balance sender) amount),
            total-supplied: (+ (get-total-supplied sender) amount),
            last-update-block: block-height
        }
    )

    ;; Update user balance
    (map-set user-balances
        sender
        (- current-balance amount)
    )

    (ok true)
    )
)

;; Initiate cross-chain transfer
(define-public (initiate-transfer 
    (amount uint)
    (recipient principal)
    (target-chain (string-utf8 32))
    (max-slippage uint)
)
    (let (
        (sender tx-sender)
        (transfer-id (var-get transfer-nonce))
        (fee (calculate-fee amount))
        (final-amount (- amount fee))
    )
        ;; Validate inputs
        (asserts! (is-valid-recipient recipient) err-invalid-recipient)
        (asserts! (is-valid-chain target-chain) err-invalid-chain)
        
        ;; Existing checks
        (asserts! (not (var-get bridge-paused)) err-bridge-paused)
        (asserts! (>= amount (var-get min-transfer-amount)) err-invalid-amount)
        (asserts! (<= amount (var-get max-transfer-amount)) err-invalid-amount)
        (asserts! (check-slippage amount max-slippage) err-slippage-exceeded)

        ;; Create pending transfer with validated data
        (map-set pending-transfers
            transfer-id
            {
                sender: sender,
                recipient: recipient,
                amount: final-amount,
                target-chain: target-chain,
                status: u"pending"
            }
        )

        ;; Update nonce
        (var-set transfer-nonce (+ transfer-id u1))

        (ok transfer-id)
    )
)

;; Complete transfer (called by bridge validators)
(define-public (complete-transfer (transfer-id uint))
    (begin
        ;; Validate transfer-id
        (asserts! (is-valid-transfer-id transfer-id) err-invalid-transfer-id)
        
        (let (
            (transfer (unwrap! (map-get? pending-transfers transfer-id) err-invalid-pool))
        )
            (asserts! (not (var-get bridge-paused)) err-bridge-paused)
            
            ;; Validate recipient again as an extra security measure
            (asserts! (is-valid-recipient (get recipient transfer)) err-invalid-recipient)

            ;; Update transfer status
            (map-set pending-transfers
                transfer-id
                (merge transfer { status: u"completed" })
            )

            ;; Add amount to recipient balance with validated data
            (map-set user-balances
                (get recipient transfer)
                (+ (default-to u0 (map-get? user-balances (get recipient transfer)))
                   (get amount transfer))
            )

            (ok true)
        )
    )
)

;; Administrative functions with validation

;; Update oracle price with validation
(define-public (update-oracle-price (new-price uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        ;; Validate price is within reasonable bounds
        (asserts! (and (> new-price u0) (<= new-price max-price)) err-invalid-price)
        (var-set oracle-price new-price)
        (ok true)
    )
)

;; Update fee rate with validation
(define-public (update-fee-rate (new-rate uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        ;; Validate fee rate is within reasonable bounds (0-10%)
        (asserts! (<= new-rate max-fee-rate) err-invalid-fee-rate)
        (var-set bridge-fee-rate new-rate)
        (ok true)
    )
)

;; Pause bridge (emergency)
(define-public (pause-bridge)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set bridge-paused true)
        (ok true)
    )
)

;; Resume bridge
(define-public (resume-bridge)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set bridge-paused false)
        (ok true)
    )
)

;; Read-only functions

;; Get pool balance
(define-read-only (get-pool-balance (pool principal))
    (default-to u0 
        (get balance 
            (map-get? liquidity-pools pool)
        )
    )
)

;; Get total supplied
(define-read-only (get-total-supplied (pool principal))
    (default-to u0 
        (get total-supplied 
            (map-get? liquidity-pools pool)
        )
    )
)

;; Get transfer details
(define-read-only (get-transfer (transfer-id uint))
    (map-get? pending-transfers transfer-id)
)

;; Private functions

;; Calculate fee
(define-private (calculate-fee (amount uint))
    (/ (* amount (var-get bridge-fee-rate)) u10000)
)

;; Check slippage
(define-private (check-slippage (amount uint) (max-slippage uint))
    (let (
        (current-price (var-get oracle-price))
    )
        (<= (* amount current-price) (* amount (+ u1000000 max-slippage)))
    )
)
