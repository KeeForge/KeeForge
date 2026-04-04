import SwiftUI

struct SettingsView: View {
    var viewModel: DatabaseViewModel? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var autoLockTimeout = SettingsService.autoLockTimeout
    @State private var clipboardTimeout = SettingsService.clipboardTimeout
    @State private var autoUnlockWithFaceID = SettingsService.autoUnlockWithFaceID
    @State private var showWebsiteIcons = SettingsService.showWebsiteIcons
    @State private var quickAutoFillEnabled = SettingsService.quickAutoFillEnabled
    @State private var sortOrder = DatabaseViewModel.savedSortOrder()
    @State private var sortAscending = DatabaseViewModel.savedSortAscending()
    @State private var cloudAccounts = CloudAccountStore.accounts

    var body: some View {
        NavigationStack {
            Form {
                securitySection
                autoFillSection
                cloudAccountsSection
                displaySection
                faviconCacheSection
                TipJarView()
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: autoLockTimeout) { _, newValue in
                SettingsService.autoLockTimeout = newValue
            }
            .onChange(of: clipboardTimeout) { _, newValue in
                SettingsService.clipboardTimeout = newValue
            }
            .onChange(of: autoUnlockWithFaceID) { _, newValue in
                SettingsService.autoUnlockWithFaceID = newValue
            }
            .onChange(of: showWebsiteIcons) { _, newValue in
                SettingsService.showWebsiteIcons = newValue
            }
            .onChange(of: quickAutoFillEnabled) { _, newValue in
                SettingsService.quickAutoFillEnabled = newValue
                if newValue {
                    viewModel?.populateCredentialStoreIfUnlocked()
                } else {
                    CredentialIdentityStoreManager.clearStore()
                }
            }
            .onChange(of: sortOrder) { _, newValue in
                DatabaseViewModel.persistSortOrder(newValue)
                viewModel?.sortOrder = newValue
            }
            .onChange(of: sortAscending) { _, newValue in
                DatabaseViewModel.persistSortAscending(newValue)
                viewModel?.sortAscending = newValue
            }
            .onAppear {
                cloudAccounts = CloudAccountStore.accounts
            }
        }
    }

    private var securitySection: some View {
        Section {
            Toggle("Auto-Unlock with Face ID", isOn: $autoUnlockWithFaceID)

            Picker("Auto-Lock Timeout", selection: $autoLockTimeout) {
                ForEach(SettingsService.AutoLockTimeout.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }

            Picker("Clipboard Clear Timeout", selection: $clipboardTimeout) {
                ForEach(SettingsService.ClipboardTimeout.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
        } header: {
            Text("Security")
        } footer: {
            Text("Auto-Unlock with Face ID prompts after a database is opened. Quick Launch controls whether a database opens automatically on app launch.")
        }
    }

    private var autoFillSection: some View {
        Section {
            Toggle("Quick AutoFill", isOn: $quickAutoFillEnabled)
        } header: {
            Text("AutoFill")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("KeeForge currently autofills from the last database you successfully opened.")

                if quickAutoFillEnabled {
                    Text("Credential suggestions appear in the keyboard bar. Requires Face ID to unlock when tapped.")
                }
            }
        }
    }

    private var displaySection: some View {
        Section {
            Toggle("Download Website Favicons", isOn: $showWebsiteIcons)

            Picker("Default Sort Order", selection: $sortOrder) {
                ForEach(DatabaseViewModel.SortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }

            Picker("Sort Direction", selection: $sortAscending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
        } header: {
            Text("Display")
        } footer: {
            if showWebsiteIcons {
                Text("Fetches icons from DuckDuckGo. Only the website domain is sent.")
            }
        }
    }

    @ViewBuilder
    private var cloudAccountsSection: some View {
        Section {
            if cloudAccounts.isEmpty {
                Text("No cloud accounts connected")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(cloudAccounts) { account in
                    HStack {
                        Label(
                            account.displayName,
                            systemImage: account.providerKind?.iconName ?? "icloud"
                        )

                        Spacer()

                        Button("Sign Out", role: .destructive) {
                            CloudProviderRegistry.provider(for: account.provider)?.signOut(accountId: account.id)
                            cloudAccounts = CloudAccountStore.accounts
                        }
                    }
                }
            }
        } header: {
            Text("Cloud Accounts")
        } footer: {
            Text("Signing out disconnects future syncs but keeps cached cloud databases available until you remove them.")
        }
    }

    @ViewBuilder
    private var faviconCacheSection: some View {
        if showWebsiteIcons {
            Section {
                Button("Clear Favicon Cache", role: .destructive) {
                    FaviconService.clearCache()
                }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: "KeeForge")

            LabeledContent("Version", value: appVersion)

            Link(destination: URL(string: "mailto:support@keeforge.com")!) {
                Label("Contact Support", systemImage: "envelope")
            }

            Link(destination: URL(string: "https://github.com/crazytan/KeeForge/issues")!) {
                Label("Report a Bug", systemImage: "ladybug")
            }

            Link(destination: URL(string: "https://github.com/crazytan/KeeForge")!) {
                Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
            }

            NavigationLink {
                AcknowledgmentsView()
            } label: {
                Label("Acknowledgments", systemImage: "doc.text")
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
        let commit = Bundle.main.infoDictionary?["GITCommitHash"] as? String ?? "dev"
        return "\(version) (\(commit))"
    }
}
