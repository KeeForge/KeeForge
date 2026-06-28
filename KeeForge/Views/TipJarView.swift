import StoreKit
import SwiftUI

struct TipJarView: View {
    private var store: StoreKitManager { StoreKitManager.shared }
    @State private var showThankYou = false

    @State private var loadingDone = false

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
            if case .success = result {
                showThankYou = true
            }
        }
        .alert("Thank You! 🎉", isPresented: $showThankYou) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your support means the world. Thank you for helping keep KeeForge alive!")
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
            }
            .disabled(store.isPurchasing)
        }
    }
}
