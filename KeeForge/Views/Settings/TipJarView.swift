import StoreKit
import SwiftUI

struct TipJarView: View {
    private var store: StoreKitManager { StoreKitManager.shared }
    @State private var showThankYou = false
    @State private var purchaseNotice: PurchaseNotice?

    @State private var loadingDone = false

    private struct PurchaseNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        Section {
            if store.tips.isEmpty && !loadingDone {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if store.tips.isEmpty {
                Text("Tip Jar is not available right now.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else if store.hasTipped {
                thankedSupporterContent
            } else {
                tipButtons
            }

            buyMeACoffeeLink
        } header: {
            Text("Tip Jar")
        } footer: {
            Text("KeeForge is free and open source. Tips help support development. ❤️")
        }
        .task {
            await store.loadProducts()
            await store.refreshTipHistory()
            loadingDone = true
        }
        .onChange(of: store.purchaseResult) { _, result in
            switch result {
            case .success:
                showThankYou = true
            case .pending:
                purchaseNotice = PurchaseNotice(
                    title: "Purchase Pending",
                    message: "Your tip needs approval before it completes (for example, via Ask to Buy). It'll finish automatically once approved."
                )
            case .error(let message):
                purchaseNotice = PurchaseNotice(
                    title: "Purchase Failed",
                    message: message
                )
            case .cancelled, nil:
                break
            }
        }
        .alert("Thank You! 🎉", isPresented: $showThankYou) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your support means the world. Thank you for helping keep KeeForge alive!")
        }
        .alert(item: $purchaseNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var thankedSupporterContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                Text("Thank you for tipping!")
                    .foregroundStyle(.primary)
            }
            Text("Your support helps keep KeeForge free and open source.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("tip-jar.thank-you")

        Menu {
            ForEach(store.tips, id: \.id) { product in
                Button {
                    Task { await store.purchase(product) }
                } label: {
                    Text("\(product.displayName) - \(product.displayPrice)")
                }
            }
        } label: {
            Label("Tip again", systemImage: "heart")
        }
        .disabled(store.isPurchasing)
        .accessibilityIdentifier("tip-jar.tip-again.menu")
    }

    private var buyMeACoffeeLink: some View {
        Link(destination: URL(string: "https://buymeacoffee.com/crazytan")!) {
            Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
        }
        .accessibilityIdentifier("tip-jar.buy-me-a-coffee")
    }

    private var tipButtons: some View {
        ForEach(store.tips, id: \.id) { product in
            Button {
                Task { await store.purchase(product) }
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(product.displayName)
                            .foregroundStyle(.primary)
                        Text(product.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(product.displayPrice)
                        .font(.callout.bold())
                        .foregroundStyle(.blue)
                }
                .contentShape(Rectangle())
            }
            .macPlainRowButton()
            .disabled(store.isPurchasing)
        }
    }
}
