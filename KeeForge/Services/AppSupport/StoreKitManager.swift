import Observation
import StoreKit

@Observable
@MainActor
final class StoreKitManager {
    static let shared = StoreKitManager()

    private(set) var tips: [Product] = []
    private(set) var isPurchasing = false
    private(set) var purchaseResult: PurchaseResult?
    private(set) var hasTipped = SettingsService.hasTipped

    enum PurchaseResult: Equatable {
        case success
        case cancelled
        case pending
        case error(String)
    }

    static let tipProductIDs: [String] = [
        "com.keevault.app.tip.small",
        "com.keevault.app.tip.nice",
        "com.keevault.app.tip.big",
    ]

    private static let tipProductIDSet = Set(tipProductIDs)

    private var updatesTask: Task<Void, Never>?

    private init() {
        start()
    }

    /// Starts the `Transaction.updates` listener if it is not already running.
    ///
    /// Idempotent, so it is safe to call from both `init` and app launch. Touch
    /// `StoreKitManager.shared` (which calls this via `init`) early at launch so
    /// out-of-app transaction completions — Ask to Buy approvals, deferred SCA,
    /// and purchases interrupted before `finish()` — are delivered and finished
    /// even when the Tip Jar is never opened. The singleton guarantees a single
    /// listener regardless of how many callers touch `shared`.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = listenForTransactions()
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handleTransactionUpdate(result)
            }
        }
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await finishVerifiedTransaction(transaction)
    }

    private func finishVerifiedTransaction(_ transaction: Transaction) async {
        if isActiveTipTransaction(transaction) {
            rememberTip()
        }
        await transaction.finish()
    }

    private func isActiveTipTransaction(_ transaction: Transaction) -> Bool {
        Self.tipProductIDSet.contains(transaction.productID) && transaction.revocationDate == nil
    }

    private func rememberTip() {
        guard !hasTipped else { return }
        SettingsService.hasTipped = true
        hasTipped = true
    }

    func loadProducts() async {
        do {
            let products = try await Product.products(for: Self.tipProductIDs)
            tips = products.sorted { $0.price < $1.price }
        } catch {
            // A transient load failure (e.g. no network) must not wipe a list
            // that was already fetched successfully. Leave any previously loaded
            // tips in place; if nothing was ever loaded, `tips` stays empty and
            // the view surfaces the "not available" state once loading finishes.
        }
    }

    /// Best-effort reconciliation of the persisted tip flag from StoreKit history.
    ///
    /// Tips are consumable products, so completed purchases only appear in
    /// `Transaction.all` on iOS 18+/macOS 15+ (and only with
    /// `SKIncludeConsumableInAppPurchaseHistory` set in Info.plist, which it is).
    /// Our iOS minimum is now 18, but the macOS minimum is still 14, so on
    /// macOS 14 this history can be empty even for someone who has tipped;
    /// the persisted `SettingsService.hasTipped` flag remains the source of
    /// truth. This method
    /// only ever *promotes* `hasTipped` to true via `rememberTip()` and never
    /// regresses a previously recorded tip back to false.
    func refreshTipHistory() async {
        for await result in Transaction.all {
            guard case .verified(let transaction) = result else { continue }
            if isActiveTipTransaction(transaction) {
                rememberTip()
                return
            }
        }
    }

    func purchase(_ product: Product) async {
        isPurchasing = true
        purchaseResult = nil

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await finishVerifiedTransaction(transaction)
                    purchaseResult = .success
                case .unverified:
                    purchaseResult = .error("Transaction could not be verified.")
                }
            case .userCancelled:
                purchaseResult = .cancelled
            case .pending:
                // Ask to Buy / deferred SCA: the purchase is neither done nor
                // cancelled. Surface it distinctly so the user gets honest
                // feedback instead of silence. The `Transaction.updates`
                // listener finishes it once (and if) it is approved.
                purchaseResult = .pending
            @unknown default:
                purchaseResult = .error("Unknown purchase result.")
            }
        } catch {
            purchaseResult = .error(error.localizedDescription)
        }

        isPurchasing = false
    }
}
