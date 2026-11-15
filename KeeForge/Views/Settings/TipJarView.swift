#if !KEEFORGE_DIRECT_DOWNLOAD
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
        content
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
                    title: String(localized: "Purchase Pending"),
                    message: String(localized: "Your tip needs approval before it completes (for example, via Ask to Buy). It'll finish automatically once approved.")
                )
            case .error(let message):
                purchaseNotice = PurchaseNotice(
                    title: String(localized: "Purchase Failed"),
                    message: message
                )
            case .cancelled, nil:
                break
            }
        }
        .alert(thankYouTitle, isPresented: $showThankYou) {
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
    private var products: some View {
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
    }

    #if os(macOS)
    /// Sits in the About tab's control column, whose label already names it.
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.tips.isEmpty || store.hasTipped {
                products
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.tips.enumerated()), id: \.element.id) { index, product in
                        if index > 0 { Divider() }
                        macTipRow(product)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .frame(maxWidth: 400)
            }
            buyMeACoffeeLink
            Text("KeeForge is free and open source. Tips help support development.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func macTipRow(_ product: Product) -> some View {
        Button {
            Task { await store.purchase(product) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(product.displayName).foregroundStyle(Color.primary)
                    Text(product.description).font(.caption).foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
                Text(product.displayPrice).monospacedDigit().foregroundStyle(Color.primary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .macPlainRowButton()
        .disabled(store.isPurchasing)
    }
    #else
    private var content: some View {
        Section {
            products
            buyMeACoffeeLink
        } header: {
            Text("Tip Jar")
        } footer: {
            Text("KeeForge is free and open source. Tips help support development. ❤️")
        }
    }
    #endif

    private var thankYouTitle: LocalizedStringKey {
        #if os(macOS)
        "Thank You!"
        #else
        "Thank You! 🎉"
        #endif
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
                        // `Color.primary`, not `.primary`: inside a button
                        // label the hierarchical styles follow the tint.
                        Text(product.description)
                            .font(.caption)
                            .foregroundStyle(Color.primary)
                    }
                    Spacer()
                    Text(product.displayPrice)
                        .font(.callout.bold())
                        .foregroundStyle(Color.primary)
                }
                .contentShape(Rectangle())
            }
            .macPlainRowButton()
            .disabled(store.isPurchasing)
        }
    }
}
#endif
