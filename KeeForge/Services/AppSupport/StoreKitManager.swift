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
            tips = []
        }
    }

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
                purchaseResult = .cancelled
            @unknown default:
                purchaseResult = .error("Unknown purchase result.")
            }
        } catch {
            purchaseResult = .error(error.localizedDescription)
        }

        isPurchasing = false
    }
}
