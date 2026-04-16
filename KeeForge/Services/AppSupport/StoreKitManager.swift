import StoreKit
import SwiftUI

@Observable
@MainActor
final class StoreKitManager {
    static let shared = StoreKitManager()

    private(set) var tips: [Product] = []
    private(set) var isPurchasing = false
    private(set) var purchaseResult: PurchaseResult?

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

    private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = listenForTransactions()
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
            }
        }
    }

    func loadProducts() async {
        do {
            let products = try await Product.products(for: Self.tipProductIDs)
            tips = products.sorted { $0.price < $1.price }
        } catch {
            tips = []
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
                    await transaction.finish()
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
