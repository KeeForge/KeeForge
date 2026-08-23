import AuthenticationServices
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct CloudFileBrowserView: View {
    let providerID: String
    let onSelect: (CloudDatabaseSelection) -> Void
    let onFailure: (Error) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var session: CloudFileBrowserSession
    @State private var isWebDAVConnectPresented = false

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
                                    fallbackSystemName: provider.iconName
                                )
                            }
                        } description: {
                            VStack(spacing: 8) {
                                Text("Sign in to browse your \(provider.displayName) databases.")
                                DropboxLowUserWarningNote(provider: provider)
                            }
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
        .sheet(isPresented: $isWebDAVConnectPresented) {
            if let connector = session.provider as? WebDAVConnecting {
                WebDAVConnectView(
                    connector: connector,
                    onConnected: { account in
                        session.adoptManualAccount(account)
                        isWebDAVConnectPresented = false
                    },
                    onCancel: {
                        isWebDAVConnectPresented = false
                    }
                )
            }
        }
    }

    private func beginAuthentication() {
        if session.usesManualConnectionForm {
            isWebDAVConnectPresented = true
            return
        }

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
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        return ASPresentationAnchor()
        #else
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
            return window
        }
        return ASPresentationAnchor()
        #endif
    }
}

struct CloudFolderSelection: Hashable, Sendable {
    let provider: String
    let account: CloudAccount
    let folderPath: String?
    let displayPath: String
}

struct CloudFolderPickerView: View {
    let providerID: String
    let onSelect: (CloudFolderSelection) -> Void
    let onFailure: (Error) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var session: CloudFileBrowserSession
    @State private var isWebDAVConnectPresented = false

    init(
        providerID: String,
        onSelect: @escaping (CloudFolderSelection) -> Void,
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
                        CloudDestinationFolderBrowserView(
                            provider: provider,
                            account: selectedAccount,
                            initialPath: nil,
                            displayPath: provider.displayName,
                            onSelect: handleFolderSelection
                        )
                    } else {
                        ContentUnavailableView {
                            Label {
                                Text("Connect \(provider.displayName)")
                            } icon: {
                                CloudProviderIcon(
                                    provider: CloudProviderKind(rawValue: provider.id),
                                    fallbackSystemName: provider.iconName
                                )
                            }
                        } description: {
                            VStack(spacing: 8) {
                                Text("Sign in to browse your \(provider.displayName) folders.")
                                DropboxLowUserWarningNote(provider: provider)
                            }
                        } actions: {
                            Button("Connect") {
                                beginAuthentication()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(session.isAuthenticating)
                            .accessibilityIdentifier("cloud.folder.connect.button")
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
                    .accessibilityIdentifier("cloud.folder.cancel.button")
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
                        .accessibilityIdentifier("cloud.folder.account.menu")
                    }
                }
            }
        }
        .task {
            session.refreshAccounts()
        }
        .sheet(isPresented: $isWebDAVConnectPresented) {
            if let connector = session.provider as? WebDAVConnecting {
                WebDAVConnectView(
                    connector: connector,
                    onConnected: { account in
                        session.adoptManualAccount(account)
                        isWebDAVConnectPresented = false
                    },
                    onCancel: {
                        isWebDAVConnectPresented = false
                    }
                )
            }
        }
    }

    private func beginAuthentication() {
        if session.usesManualConnectionForm {
            isWebDAVConnectPresented = true
            return
        }

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
    private func handleFolderSelection(folderPath: String?, displayPath: String) {
        guard let selectedAccount = session.selectedAccount else { return }
        onSelect(
            CloudFolderSelection(
                provider: providerID,
                account: selectedAccount,
                folderPath: folderPath,
                displayPath: displayPath
            )
        )
        dismiss()
    }

    @MainActor
    private func presentationAnchor() -> ASPresentationAnchor {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        return ASPresentationAnchor()
        #else
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first {
            return window
        }
        return ASPresentationAnchor()
        #endif
    }
}

private struct DropboxLowUserWarningNote: View {
    let provider: CloudProvider

    var body: some View {
        if provider.id == CloudProviderKind.dropbox.rawValue {
            Text("Note: Dropbox may warn that KeeForge has low number of users. That is normal for an indie app. KeeForge is open source and will only use the database file you choose to open or create.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Renders a cloud provider glyph as a symbol image so it inherits font,
/// weight, tint, and dark/light appearance from its context exactly like a
/// built-in SF Symbol. Dropbox and OneDrive are custom template symbols in
/// the asset catalog; WebDAV uses a system symbol.
struct CloudProviderIcon: View {
    let provider: CloudProviderKind?
    var fallbackSystemName = "icloud"

    var body: some View {
        switch provider {
        case .dropbox:
            Image("DropboxGlyph")
        case .oneDrive:
            Image("OneDriveGlyph")
        case .webDAV:
            Image(systemName: CloudProviderKind.webDAV.iconName)
        case .none:
            Image(systemName: fallbackSystemName)
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

private struct CloudDestinationFolderBrowserView: View {
    let provider: CloudProvider
    let account: CloudAccount
    let initialPath: String?
    let displayPath: String
    let onSelect: (_ folderPath: String?, _ displayPath: String) -> Void

    @State private var viewModel: CloudFolderBrowserViewModel

    init(
        provider: CloudProvider,
        account: CloudAccount,
        initialPath: String?,
        displayPath: String,
        onSelect: @escaping (_ folderPath: String?, _ displayPath: String) -> Void
    ) {
        self.provider = provider
        self.account = account
        self.initialPath = initialPath
        self.displayPath = displayPath
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
                    "Couldn’t Load Folders",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if folderFiles.isEmpty {
                ContentUnavailableView(
                    "No Folders",
                    systemImage: "folder",
                    description: Text("This location has no subfolders.")
                )
            } else {
                List(folderFiles) { folder in
                    NavigationLink {
                        CloudDestinationFolderBrowserView(
                            provider: provider,
                            account: account,
                            initialPath: folder.id,
                            displayPath: folder.path,
                            onSelect: onSelect
                        )
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                    .accessibilityIdentifier("cloud.folder.row")
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create Here") {
                    onSelect(initialPath, displayPath)
                }
                .accessibilityIdentifier("cloud.folder.create-here")
            }
        }
        .task(id: viewModel.requestKey(accountID: account.id)) {
            await viewModel.load(provider: provider, accountID: account.id)
        }
    }

    private var folderFiles: [CloudFile] {
        viewModel.files.filter(\.isFolder)
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
