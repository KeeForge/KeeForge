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
    @State private var pendingCloudAccountSignOut: CloudAccount?
    @State private var feedbackContext: FeedbackComposerContext?

    var body: some View {
        NavigationStack {
            Form {
                securitySection
                autoFillSection
                cloudAccountsSection
                displaySection
                faviconCacheSection
                TipJarView()
                supportSection
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
        .sheet(item: $feedbackContext) { context in
            FeedbackComposerView(context: context)
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
                        Label {
                            Text(account.displayName)
                        } icon: {
                            CloudProviderIcon(provider: account.providerKind, size: 20)
                        }
                        .accessibilityIdentifier("settings.cloud.account.label")

                        Spacer()

                        Button("Sign Out", role: .destructive) {
                            pendingCloudAccountSignOut = account
                        }
                        .confirmationDialog(
                            "Disconnect Cloud Account?",
                            isPresented: Binding(
                                get: { pendingCloudAccountSignOut?.id == account.id },
                                set: { isPresented in
                                    if !isPresented {
                                        pendingCloudAccountSignOut = nil
                                    }
                                }
                            )
                        ) {
                            Button("Disconnect", role: .destructive) {
                                CloudProviderRegistry.provider(for: account.provider)?.signOut(accountId: account.id)
                                cloudAccounts = CloudAccountStore.accounts
                                pendingCloudAccountSignOut = nil
                            }

                            Button("Cancel", role: .cancel) {
                                pendingCloudAccountSignOut = nil
                            }
                        } message: {
                            Text("Disconnect \(account.displayName)? KeeForge will keep any cached cloud databases until you remove them.")
                        }
                        .accessibilityIdentifier("settings.cloud.signout.button")
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

    private var supportSection: some View {
        Section {
            Button {
                feedbackContext = .general
            } label: {
                Label("Send Feedback", systemImage: "paperplane")
            }
            .accessibilityIdentifier("settings.send-feedback")
        } header: {
            Text("Support")
        } footer: {
            Text("No GitHub or email required. KeeForge never includes database contents, passwords, key files, or raw vault files in feedback. This build currently uses a placeholder feedback endpoint.")
        }
    }

    private var appVersion: String {
        let environment = AppFeedbackEnvironment.current()
        return "\(environment.appVersion) (\(environment.buildNumber))"
    }
}
