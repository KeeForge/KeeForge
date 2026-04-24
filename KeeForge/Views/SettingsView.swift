import SwiftUI

struct SettingsView: View {
    var viewModel: DatabaseViewModel? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var autoLockTimeout = SettingsService.autoLockTimeout
    @State private var lockOnBackground = SettingsService.lockOnBackground
    @State private var clipboardTimeout = SettingsService.clipboardTimeout
    @State private var autoUnlockWithFaceID = SettingsService.autoUnlockWithFaceID
    @State private var showWebsiteIcons = SettingsService.showWebsiteIcons
    @State private var showDatabaseUsageStats = SettingsService.showDatabaseUsageStats
    @State private var quickAutoFillEnabled = SettingsService.quickAutoFillEnabled
    @State private var sortOrder = DatabaseViewModel.savedSortOrder()
    @State private var sortAscending = DatabaseViewModel.savedSortAscending()
    @State private var cloudAccounts = CloudAccountStore.accounts
    @State private var pendingCloudAccountSignOut: CloudAccount?
    @State private var feedbackContext: FeedbackComposerContext?

    var body: some View {
        NavigationStack {
            Form {
                settingsNavigationSection
                TipJarView()
                cloudAccountsSection
                feedbackSection
                aboutNavigationSection
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
                viewModel?.resetInactivityTimer()
            }
            .onChange(of: lockOnBackground) { _, newValue in
                SettingsService.lockOnBackground = newValue
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
            .onChange(of: showDatabaseUsageStats) { _, newValue in
                SettingsService.showDatabaseUsageStats = newValue
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

    private var settingsNavigationSection: some View {
        Section {
            NavigationLink {
                SecuritySettingsView(
                    autoLockTimeout: $autoLockTimeout,
                    lockOnBackground: $lockOnBackground,
                    clipboardTimeout: $clipboardTimeout,
                    autoUnlockWithFaceID: $autoUnlockWithFaceID
                )
            } label: {
                Label("Security", systemImage: "lock.shield")
            }
            .accessibilityIdentifier("settings.security.link")

            NavigationLink {
                AutoFillSettingsView(quickAutoFillEnabled: $quickAutoFillEnabled)
            } label: {
                Label("AutoFill", systemImage: "text.cursor")
            }
            .accessibilityIdentifier("settings.autofill.link")

            NavigationLink {
                DisplaySettingsView(
                    showWebsiteIcons: $showWebsiteIcons,
                    showDatabaseUsageStats: $showDatabaseUsageStats,
                    sortOrder: $sortOrder,
                    sortAscending: $sortAscending
                )
            } label: {
                Label("Display", systemImage: "eye")
            }
            .accessibilityIdentifier("settings.display.link")
        }
    }

    private var aboutNavigationSection: some View {
        Section {
            NavigationLink {
                AboutSettingsView()
            } label: {
                Label("About", systemImage: "info.circle")
            }
            .accessibilityIdentifier("settings.about.link")
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

    private var feedbackSection: some View {
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
            Text("No GitHub or email required. KeeForge only sends the message you type, plus the visible error details if you report a database-open failure. It never includes database contents, passwords, key files, raw vault files, or app/device metadata.")
        }
    }

}

private struct SecuritySettingsView: View {
    @Binding var autoLockTimeout: SettingsService.AutoLockTimeout
    @Binding var lockOnBackground: Bool
    @Binding var clipboardTimeout: SettingsService.ClipboardTimeout
    @Binding var autoUnlockWithFaceID: Bool

    var body: some View {
        Form {
            Section {
                Toggle("Auto-Unlock with Face ID", isOn: $autoUnlockWithFaceID)
                Toggle("Lock When App Goes to Background", isOn: $lockOnBackground)

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
            } footer: {
                Text("Auto-Unlock with Face ID prompts after a database is opened. When background locking is off, KeeForge still uses the auto-lock timeout and locks the next time the app becomes active after that deadline has passed.")
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AutoFillSettingsView: View {
    @Binding var quickAutoFillEnabled: Bool

    var body: some View {
        Form {
            Section {
                Toggle("Quick AutoFill", isOn: $quickAutoFillEnabled)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("KeeForge currently autofills from the last database you successfully opened.")

                    if quickAutoFillEnabled {
                        Text("Credential suggestions appear in the keyboard bar. Requires Face ID to unlock when tapped.")
                    }
                }
            }
        }
        .navigationTitle("AutoFill")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DisplaySettingsView: View {
    @Binding var showWebsiteIcons: Bool
    @Binding var showDatabaseUsageStats: Bool
    @Binding var sortOrder: DatabaseViewModel.SortOrder
    @Binding var sortAscending: Bool

    var body: some View {
        Form {
            privacySection
            displaySection
            sortSection

            if showWebsiteIcons {
                Section {
                    Button("Clear Favicon Cache", role: .destructive) {
                        FaviconService.clearCache()
                    }
                    .accessibilityIdentifier("settings.display.clear-favicon-cache")
                }
            }
        }
        .navigationTitle("Display")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var privacySection: some View {
        Section {
            Toggle("Show Usage Stats in Database List", isOn: $showDatabaseUsageStats)
                .accessibilityIdentifier("settings.display.usage-stats-toggle")
        } header: {
            Text("Privacy")
        } footer: {
            Text("When off, KeeForge hides last-opened activity from the locked database list.")
        }
    }

    private var displaySection: some View {
        Section {
            Toggle("Download Website Favicons", isOn: $showWebsiteIcons)
                .accessibilityIdentifier("settings.display.favicons-toggle")
        } header: {
            Text("Display")
        } footer: {
            if showWebsiteIcons {
                Text("Fetches icons from DuckDuckGo. Only the website domain is sent.")
            }
        }
    }

    private var sortSection: some View {
        Section("Entry List") {
            Picker("Default Sort Order", selection: $sortOrder) {
                ForEach(DatabaseViewModel.SortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }

            Picker("Sort Direction", selection: $sortAscending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
        }
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        Form {
            aboutSection
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
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
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let commit = bundle.object(forInfoDictionaryKey: "GITCommitHash") as? String
        let trimmedCommit = commit?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayCommit = if let trimmedCommit, trimmedCommit.isEmpty == false {
            trimmedCommit
        } else {
            "dev"
        }
        return "\(version) (\(displayCommit))"
    }
}
