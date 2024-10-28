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

;; Data Variables
(define-data-var bridge-paused bool false)
(define-data-var min-transfer-amount uint u100000) ;; in micro units
(define-data-var max-transfer-amount uint u1000000000000) ;; in micro units
(define-data-var bridge-fee-rate uint u25) ;; 0.25% = 25 basis points
(define-data-var oracle-price uint u1000000) ;; price with 6 decimal places

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

;; Counter for transfer IDs
(define-data-var transfer-nonce uint u0)

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
        (asserts! (not (var-get bridge-paused)) err-bridge-paused)
        (asserts! (>= amount (var-get min-transfer-amount)) err-invalid-amount)
        (asserts! (<= amount (var-get max-transfer-amount)) err-invalid-amount)
        (asserts! (check-slippage amount max-slippage) err-slippage-exceeded)

        ;; Create pending transfer
        (map-set pending-transfers
            transfer-id
            {
                sender: sender,
                recipient: recipient,
                amount: final-amount,
                target-chain: target-chain,
                status: "pending"
            }
        )

        ;; Update nonce
        (var-set transfer-nonce (+ transfer-id u1))

        (ok transfer-id)
    )
)

;; Complete transfer (called by bridge validators)
(define-public (complete-transfer (transfer-id uint))
    (let (
        (transfer (unwrap! (map-get? pending-transfers transfer-id) err-invalid-pool))
    )
        (asserts! (not (var-get bridge-paused)) err-bridge-paused)

        ;; Update transfer status
        (map-set pending-transfers
            transfer-id
            (merge transfer { status: "completed" })
        )

        ;; Add amount to recipient balance
        (map-set user-balances
            (get recipient transfer)
            (+ (default-to u0 (map-get? user-balances (get recipient transfer)))
               (get amount transfer))
        )

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

;; Administrative functions

;; Update oracle price (restricted to contract owner)
(define-public (update-oracle-price (new-price uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set oracle-price new-price)
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

;; Update fee rate
(define-public (update-fee-rate (new-rate uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set bridge-fee-rate new-rate)
        (ok true)
    )
)