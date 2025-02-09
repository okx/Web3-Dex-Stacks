(impl-trait .trait-ownable.ownable-trait)
(use-trait ft-trait .trait-sip-010.sip-010-trait)

(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-TOKEN-NOT-AUTHORIZED (err u1001))
(define-constant ERR-UNKNOWN-USER-ID (err u1005))
(define-constant ERR-UNKNOWN-VALIDATOR-ID (err u1006))
(define-constant ERR-USER-ALREADY-REGISTERED (err u1007))
(define-constant ERR-VALIDATOR-ALREADY-REGISTERED (err u1008))
(define-constant ERR-DUPLICATE-SIGNATURE (err u1009))
(define-constant ERR-ORDER-HASH-MISMATCH (err u1010))
(define-constant ERR-INVALID-SIGNATURE (err u1011))
(define-constant ERR-UKNOWN-RELAYER (err u1012))
(define-constant ERR-REQUIRED-VALIDATORS (err u1013))
(define-constant ERR-ORDER-ALREADY-SENT (err u1014))
(define-constant ERR-PAUSED (err u1015))
(define-constant ERR-USER-NOT-WHITELISTED (err u1016))
(define-constant ERR-AMOUNT-LESS-THAN-MIN-FEE (err u1017))
(define-constant ERR-UNKNOWN-CHAIN-ID (err u1018))
(define-constant ERR-INVALID-AMOUNT (err u1019))

(define-constant MAX_UINT u340282366920938463463374607431768211455)
(define-constant ONE_8 u100000000)
(define-constant MAX_REQUIRED_VALIDATORS u100)

(define-constant structured-data-prefix 0x534950303138)
;; const domainHash = structuredDataHash(
;;   tupleCV({
;;     name: stringAsciiCV('ALEX Bridge'),
;;     version: stringAsciiCV('0.0.1'),
;;     'chain-id': uintCV(new StacksMainnet().chainId) | uintCV(new StacksMocknet().chainId),
;;   }),
;; );
;; (define-constant message-domain 0x57790ebb55cb7aa3d0ffb493faf4fa3a8513cc07323280dac9f19a442bc81809) ;;mainnet
(define-constant message-domain 0xbba6c42cb177438f5dc4c3c1c51b9e2eb0d43e6bdec927433edd123888f4ce6b) ;; testnet

(define-data-var contract-owner principal tx-sender)
(define-data-var is-paused bool true)
(define-data-var use-whitelist bool false)

(define-map approved-relayers principal bool)
(define-map whitelisted-users principal bool)

(define-data-var token-nonce uint u0)
(define-map token-id-registry principal uint)
(define-map token-registry uint { token: principal, approved: bool, burnable: bool, fee: uint, min-amount: uint, max-amount: uint, accrued-fee: uint })
(define-map token-reserve { token-id: uint, chain-id: uint } uint)
(define-map min-fee { token-id: uint, chain-id: uint } uint)

(define-data-var chain-nonce uint u0)
(define-map chain-registry uint { name: (string-utf8 256), buff-length: uint })

(define-data-var validator-nonce uint u0)
(define-map validator-id-registry principal uint)
(define-map validator-registry uint { validator: principal, validator-pubkey: (buff 33) })
(define-data-var validator-count uint u0)
(define-data-var required-validators uint MAX_UINT)

(define-map order-sent (buff 32) bool)
(define-map order-validated-by { order-hash: (buff 32), validator: principal } bool)

(define-data-var user-nonce uint u0)
(define-map user-id-registry principal uint)
(define-map user-registry uint principal)

;; temp variable
(define-data-var order-hash-to-iter (buff 32) 0x)

;; public functions

(define-public (register-user (user principal))
  (let
    (
      (reg-id (+ (var-get user-nonce) u1))
    )
    (asserts! (not (var-get is-paused)) ERR-PAUSED)
    (asserts! (or (not (var-get use-whitelist)) (is-whitelisted user)) ERR-USER-NOT-WHITELISTED)
    (asserts! (map-insert user-id-registry user reg-id) ERR-USER-ALREADY-REGISTERED)
    (map-insert user-registry reg-id user)
    (var-set user-nonce reg-id)
    (print { object: "bridge-endpoint", action: "register-user", user-id: reg-id, principal: user })
    (ok reg-id)
  )
)

(define-public (transfer-to-unwrap (token-trait <ft-trait>) (amount-in-fixed uint) (the-chain-id uint) (settle-address (buff 256)))
  (let
    (
      (sender tx-sender)
      (token (contract-of token-trait))
      (chain-details (try! (get-approved-chain-or-fail the-chain-id)))
      (token-id (try! (get-approved-token-id-or-fail token)))
      (token-details (try! (get-approved-token-or-fail token)))
      (fee (max (mul-down amount-in-fixed (get fee token-details)) (get-min-fee-or-default token-id the-chain-id)))
      (net-amount (- amount-in-fixed fee))
      (user-id (match (get-user-id tx-sender) user-id user-id (try! (register-user tx-sender))))
    )
    (asserts! (not (var-get is-paused)) ERR-PAUSED)
    (asserts! (or (not (var-get use-whitelist)) (is-whitelisted tx-sender)) ERR-USER-NOT-WHITELISTED)
    (asserts! 
      (and 
        (>= amount-in-fixed (get min-amount token-details)) 
        (<= amount-in-fixed (get max-amount token-details))
        (<= amount-in-fixed (get-token-reserve-or-default token-id the-chain-id))
      ) 
    ERR-INVALID-AMOUNT)
    (asserts! (> amount-in-fixed (get-min-fee-or-default token-id the-chain-id)) ERR-AMOUNT-LESS-THAN-MIN-FEE)
    (if (get burnable token-details)
      (begin
        (as-contract (try! (contract-call? token-trait burn-fixed net-amount sender)))
        (and (> fee u0) (try! (contract-call? token-trait transfer-fixed fee tx-sender (as-contract tx-sender) none)))
      )
      (try! (contract-call? token-trait transfer-fixed amount-in-fixed tx-sender (as-contract tx-sender) none))
    )
    (map-set token-registry token-id (merge token-details { accrued-fee: (+ (get accrued-fee token-details) fee) }))
    (map-set token-reserve { token-id: token-id, chain-id: the-chain-id } (- (get-token-reserve-or-default token-id the-chain-id) amount-in-fixed))
    (print {
      object: "bridge-endpoint",
      action: "transfer-to-unwrap",
      user-id: user-id,
      chain: (get name chain-details),
      net-amount: net-amount,
      fee-amount: fee,
      settle-address:
      (default-to 0x (slice? settle-address u0 (get buff-length chain-details))),
      token-id: token-id
    })
    (ok true)
  )
)

;; getters

(define-read-only (is-whitelisted (user principal))
  (default-to false (map-get? whitelisted-users user))
)

(define-read-only (get-user-id (user principal))
  (map-get? user-id-registry user)
)

(define-read-only (get-user-id-or-fail (user principal))
  (ok (unwrap! (get-user-id user) ERR-UNKNOWN-USER-ID))
)

(define-read-only (user-from-id (id uint))
  (map-get? user-registry id)
)

(define-read-only (user-from-id-or-fail (id uint))
  (ok (unwrap! (user-from-id id) ERR-UNKNOWN-USER-ID))
)

(define-read-only (get-validator-id (validator principal))
	(map-get? validator-id-registry validator)
)

(define-read-only (get-validator-id-or-fail (validator principal))
	(ok (unwrap! (get-validator-id validator) ERR-UNKNOWN-VALIDATOR-ID))
)

(define-read-only (validator-from-id (id uint))
	(map-get? validator-registry id)
)

(define-read-only (validator-from-id-or-fail (id uint))
	(ok (unwrap! (validator-from-id id) ERR-UNKNOWN-VALIDATOR-ID))
)

(define-read-only (get-required-validators)
  (var-get required-validators)
)

(define-read-only (get-paused)
  (var-get is-paused)
)

(define-read-only (get-approved-chain-or-fail (the-chain-id uint))
  (ok (unwrap! (map-get? chain-registry the-chain-id) ERR-UNKNOWN-CHAIN-ID))
)

(define-read-only (get-token-reserve-or-default (the-token-id uint) (the-chain-id uint))
  (default-to u0 (map-get? token-reserve { token-id: the-token-id, chain-id: the-chain-id }))
)

(define-read-only (get-min-fee-or-default (the-token-id uint) (the-chain-id uint))
  (default-to u0 (map-get? min-fee { token-id: the-token-id, chain-id: the-chain-id }))
)

;; salt should be tx hash of the source chain
(define-read-only (hash-order (order { to: uint, token: uint, amount-in-fixed: uint, chain-id: uint, salt: (buff 256) } ))
	(sha256 (default-to 0x (to-consensus-buff? order)))
)

(define-read-only (get-contract-owner)
  (ok (var-get contract-owner))
)

(define-read-only (get-approved-token-id-or-fail (token principal))
  (ok (unwrap! (map-get? token-id-registry token) ERR-TOKEN-NOT-AUTHORIZED))
)

(define-read-only (get-approved-token-by-id-or-fail (token-id uint))
  (ok (unwrap! (map-get? token-registry token-id) ERR-TOKEN-NOT-AUTHORIZED))
)

(define-read-only (get-approved-token-or-fail (token principal))
  (get-approved-token-by-id-or-fail (try! (get-approved-token-id-or-fail token)))
)

(define-read-only (check-is-approved-token (token principal))
  (ok (asserts! (get approved (try! (get-approved-token-or-fail token))) ERR-TOKEN-NOT-AUTHORIZED))
)

;; owner/priviledged functions

(define-public (transfer-to-wrap
    (order
      {
        to: uint,
        token: uint,
        amount-in-fixed: uint,
        chain-id: uint,
        salt: (buff 256)
      }
    )
    (token-trait <ft-trait>)
    (signature-packs (list 100 { signer: principal, order-hash: (buff 32), signature: (buff 65)})))
    (let
      (
        (token (contract-of token-trait))
        (order-hash (hash-order order))
        (token-details (try! (get-approved-token-or-fail token)))
        (chain-details (try! (get-approved-chain-or-fail (get chain-id order))))          
        (recipient (try! (user-from-id-or-fail (get to order))))
      )
      (asserts! (not (var-get is-paused)) ERR-PAUSED)
      (asserts! (is-some (map-get? approved-relayers tx-sender)) ERR-UKNOWN-RELAYER)
      (asserts! (>= (len signature-packs) (var-get required-validators)) ERR-REQUIRED-VALIDATORS)
      (asserts! (is-none (map-get? order-sent order-hash)) ERR-ORDER-ALREADY-SENT)
      (asserts! (is-eq (try! (get-approved-token-id-or-fail token)) (get token order)) ERR-TOKEN-NOT-AUTHORIZED)
      (var-set order-hash-to-iter order-hash)
      (try! (fold validate-signature-iter signature-packs (ok true)))    
      (if (get burnable token-details)
        (as-contract (try! (contract-call? token-trait mint-fixed (get amount-in-fixed order) recipient)))
        (as-contract (try! (contract-call? token-trait transfer-fixed (get amount-in-fixed order) tx-sender recipient none)))
      )
      (map-set token-reserve { token-id: (get token order), chain-id: (get chain-id order) } (+ (get-token-reserve-or-default (get token order) (get chain-id order)) (get amount-in-fixed order)))
      (print {
        object: "bridge-endpoint",
        action: "transfer-to-wrap",
        salt: (get salt order),
        principal: recipient,
        amount-in-fixed: (get amount-in-fixed order),
        token: (get token order),
        to: (get to order),
        chain-id: (get chain-id order)
      })
      (ok (map-set order-sent order-hash true))
    )
)

(define-public (add-validator (validator-pubkey (buff 33)) (validator principal))
	(let
		(
			(reg-id (+ (var-get validator-nonce) u1))
		)
    (try! (check-is-owner))
		(asserts! (map-insert validator-id-registry validator reg-id) ERR-VALIDATOR-ALREADY-REGISTERED)
		(map-insert validator-registry reg-id {validator: validator, validator-pubkey: validator-pubkey})
		(var-set validator-nonce reg-id)
    (var-set validator-count (+ u1 (var-get validator-count)))
		(ok (+ u1 (var-get validator-count)))
	)
)

(define-public (remove-validator (validator principal))
    (let
        (
          (reg-id (unwrap! (map-get? validator-id-registry validator) ERR-UNKNOWN-VALIDATOR-ID ))
        )
        (try! (check-is-owner))
        (map-delete validator-id-registry validator)
        (map-delete validator-registry reg-id)
        (var-set validator-count (- (var-get validator-count) u1))
        (ok (- (var-get validator-count) u1))
    )
)

(define-public (approve-relayer (relayer principal) (approved bool))
    (begin
        (try! (check-is-owner))
        (ok (map-set approved-relayers relayer approved))
    )
)

(define-public (set-required-validators (new-required-validators uint))
    (begin
        (try! (check-is-owner))
        (asserts! (< new-required-validators MAX_REQUIRED_VALIDATORS) ERR-REQUIRED-VALIDATORS)
        (ok (var-set required-validators new-required-validators))
    )
)

(define-public (set-paused (paused bool))
  (begin
    (try! (check-is-owner))
    (ok (var-set is-paused paused))
  )
)

(define-public (apply-whitelist (new-use-whitelist bool))
  (begin
    (try! (check-is-owner))
    (ok (var-set use-whitelist new-use-whitelist))
  )
)

(define-public (set-approved-chain (the-chain-id uint) (chain-details { name: (string-utf8 256), buff-length: uint }))
  (begin
    (try! (check-is-owner))
    (if (is-some (map-get? chain-registry the-chain-id))
      (begin
        (map-set chain-registry the-chain-id chain-details)
        (ok the-chain-id)
      )
      (let
        (
          (the-chain-id-next (+ (var-get chain-nonce) u1))
        )
        (var-set chain-nonce the-chain-id-next)
        (map-set chain-registry the-chain-id-next chain-details)
        (ok the-chain-id-next)
      )
    )
  )
)

(define-public (set-approved-token (token principal) (approved bool) (burnable bool) (fee uint) (min-amount uint) (max-amount uint))
	(begin
		(try! (check-is-owner))
    (match (map-get? token-id-registry token)
      token-id
      (begin
        (map-set token-registry token-id (merge (try! (get-approved-token-by-id-or-fail token-id)) { approved: approved, burnable: burnable, fee: fee, min-amount: min-amount, max-amount: max-amount }))
        (ok token-id)
      )
      (let
        (
          (token-id (+ u1 (var-get token-nonce)))
        )
        (map-set token-id-registry token token-id)
        (map-set token-registry token-id { token: token, approved: approved, burnable: burnable, fee: fee, min-amount: min-amount, max-amount: max-amount, accrued-fee: u0 })
        (var-set token-nonce token-id)
        (ok token-id)
      )
    )
	)
)

(define-public (set-min-fee (the-token-id uint) (the-chain-id uint) (the-min-fee uint))
    (begin
        (try! (check-is-owner))
        (ok (map-set min-fee { token-id: the-token-id, chain-id: the-chain-id } the-min-fee))
    )
)

(define-public (set-token-reserve (the-token-id uint) (the-chain-id uint) (the-reserve uint))
    (begin
        (try! (check-is-owner))
        (ok (map-set token-reserve { token-id: the-token-id, chain-id: the-chain-id } the-reserve))
    )
)

(define-public (collect-accrued-fee (token-trait <ft-trait>))
  (let
    (
      (token-id (try! (get-approved-token-id-or-fail (contract-of token-trait))))
      (token-details (try! (get-approved-token-or-fail (contract-of token-trait))))
    )
    (try! (check-is-owner))
    (and (> (get accrued-fee token-details) u0) (as-contract (try! (contract-call? token-trait transfer-fixed (get accrued-fee token-details) tx-sender (var-get contract-owner) none))))
    (ok (map-set token-registry token-id (merge token-details { accrued-fee: u0 })))
  )
)

(define-public (whitelist (user principal) (whitelisted bool))
  (begin
    (try! (check-is-owner))
    (ok (map-set whitelisted-users user whitelisted))
  )
)

(define-public (whitelist-many (users (list 2000 principal)) (whitelisted (list 2000 bool)))
  (ok (map whitelist users whitelisted))
)

(define-public (set-contract-owner (owner principal))
  (begin
    (try! (check-is-owner))
    (ok (var-set contract-owner owner))
  )
)

;; internal functions

(define-private (validate-order (order-hash (buff 32)) (signature-pack { signer: principal, order-hash: (buff 32), signature: (buff 65)}))
    (let
        (
            (validator (unwrap! (map-get? validator-registry (unwrap! (map-get? validator-id-registry (get signer signature-pack)) ERR-UNKNOWN-VALIDATOR-ID )) ERR-UNKNOWN-VALIDATOR-ID ))
        )
        (asserts! (is-none (map-get? order-validated-by { order-hash: order-hash, validator: (get signer signature-pack) })) ERR-DUPLICATE-SIGNATURE)
        (asserts! (is-eq order-hash (get order-hash signature-pack)) ERR-ORDER-HASH-MISMATCH)
        (asserts! (is-eq (secp256k1-recover? (sha256 (concat structured-data-prefix (concat message-domain order-hash))) (get signature signature-pack)) (ok (get validator-pubkey validator))) ERR-INVALID-SIGNATURE)
        (ok (map-set order-validated-by { order-hash: order-hash, validator: (get signer signature-pack) } true))
    )
)

(define-private (validate-signature-iter
    (signature-pack { signer: principal, order-hash: (buff 32), signature: (buff 65)})
    (previous-response (response bool uint))
    )
    (match previous-response
        prev-ok
        (validate-order (var-get order-hash-to-iter) signature-pack)
        prev-err
        previous-response
    )
)

(define-private (check-is-owner)
  (ok (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED))
)

(define-private (mul-down (a uint) (b uint))
    (/ (* a b) ONE_8)
)

(define-private (div-down (a uint) (b uint))
    (if (is-eq a u0)
        u0
        (/ (* a ONE_8) b)
   )
)

(define-private (max (a uint) (b uint))
  (if (<= a b) b a)
)

;; contract initialisation
;; (set-contract-owner .executor-dao)
