import AuthenticationServices
import SwiftUI
import UIKit

struct CloudFileBrowserView: View {
    let providerID: String
    let onSelect: (CloudDatabaseSelection) -> Void
    let onFailure: (Error) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var session: CloudFileBrowserSession

    init(
        providerID: String,
        onSelect: @escaping (CloudDatabaseSelection) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.providerID = providerID
        self.onSelect = onSelect
        self.onFailure = onFailure
        _session = State(initialValue: CloudFileBrowserSession(providerID: providerID))
    }

    private var provider: CloudProvider? {
        session.provider
    }

    var body: some View {
        NavigationStack {
            Group {
                if let provider {
                    if let selectedAccount = session.selectedAccount {
                        CloudFolderBrowserView(
                            provider: provider,
                            account: selectedAccount,
                            initialPath: nil,
                            onSelect: handleFileSelection
                        )
                    } else {
                        ContentUnavailableView {
                            Label {
                                Text("Connect \(provider.displayName)")
                            } icon: {
                                CloudProviderIcon(
                                    provider: CloudProviderKind(rawValue: provider.id),
                                    size: 40,
                                    fallbackSystemName: provider.iconName
                                )
                            }
                        } description: {
                            Text("Sign in to browse your \(provider.displayName) databases.")
                        } actions: {
                            Button("Connect") {
                                beginAuthentication()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(session.isAuthenticating)
                            .accessibilityIdentifier("cloud.browser.connect.button")
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Cloud Provider Unavailable",
                        systemImage: "icloud.slash",
                        description: Text("This cloud provider is not available in the current build.")
                    )
                }
            }
            .navigationTitle(provider?.displayName ?? "Cloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        session.cancelPendingAuthentication()
                        dismiss()
                    }
                    .accessibilityIdentifier("cloud.browser.cancel.button")
                }

                if provider != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if !session.accounts.isEmpty {
                                ForEach(session.accounts) { account in
                                    Button(account.displayName) {
                                        session.selectedAccountID = account.id
                                    }
                                }

                                Divider()
                            }

                            Button("Connect Another Account") {
                                beginAuthentication()
                            }
                        } label: {
                            Image(systemName: "person.crop.circle.badge.plus")
                        }
                        .disabled(session.isAuthenticating)
                        .accessibilityIdentifier("cloud.browser.account.menu")
                    }
                }
            }
        }
        .task {
            session.refreshAccounts()
        }
    }

    private func beginAuthentication() {
        Task {
            switch await session.authenticate(presentationAnchor: presentationAnchor) {
            case .authenticated:
                break
            case .cancelled:
                break
            case .failed(let error):
                onFailure(error)
                dismiss()
            }
        }
    }

    @MainActor
    private func handleFileSelection(_ file: CloudFile) {
        guard let selectedAccount = session.selectedAccount else { return }
        onSelect(
            CloudDatabaseSelection(
                provider: providerID,
                account: selectedAccount,
                file: file
            )
        )
        dismiss()
    }

    @MainActor
    private func presentationAnchor() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        return ASPresentationAnchor()
    }
}

struct CloudProviderIcon: View {
    let provider: CloudProviderKind?
    var size: CGFloat = 14
    var fallbackSystemName = "icloud"

    @ViewBuilder
    var body: some View {
        switch provider {
        case .dropbox:
            Image("DropboxGlyph")
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        case .none:
            Image(systemName: fallbackSystemName)
                .font(.system(size: size))
                .frame(width: size, height: size)
        }
    }
}

private struct CloudFolderBrowserView: View {
    let provider: CloudProvider
    let account: CloudAccount
    let initialPath: String?
    let onSelect: (CloudFile) -> Void

    @State private var viewModel: CloudFolderBrowserViewModel

    init(
        provider: CloudProvider,
        account: CloudAccount,
        initialPath: String?,
        onSelect: @escaping (CloudFile) -> Void
    ) {
        self.provider = provider
        self.account = account
        self.initialPath = initialPath
        self.onSelect = onSelect
        _viewModel = State(initialValue: CloudFolderBrowserViewModel(path: initialPath))
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.files.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = viewModel.errorMessage, viewModel.files.isEmpty {
                ContentUnavailableView(
                    "Couldn’t Load Files",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if viewModel.files.isEmpty {
                ContentUnavailableView(
                    "No Databases",
                    systemImage: "doc",
                    description: Text("No KeePass databases were found in this location.")
                )
            } else {
                List(viewModel.files) { file in
                    if file.isFolder {
                        NavigationLink {
                            CloudFolderBrowserView(
                                provider: provider,
                                account: account,
                                initialPath: file.id,
                                onSelect: onSelect
                            )
                        } label: {
                            Label(file.name, systemImage: "folder")
                        }
                        .accessibilityIdentifier("cloud.browser.file.row")
                    } else {
                        Button {
                            onSelect(file)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(file.name, systemImage: "doc.text")
                                Text(file.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("cloud.browser.file.row")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, placement: .navigationBarDrawer(displayMode: .automatic))
        .task(id: viewModel.requestKey(accountID: account.id)) {
            await viewModel.load(provider: provider, accountID: account.id)
        }
    }

    private var navigationTitle: String {
        if let initialPath,
           let lastComponent = initialPath.split(separator: "/").last,
           !lastComponent.isEmpty {
            return String(lastComponent)
        }

        return account.displayName
    }
}
