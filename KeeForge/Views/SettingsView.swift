import SwiftUI

struct SettingsView: View {
    var viewModel: DatabaseViewModel? = nil
    /// The app's shared `DatabaseListViewModel` — the instance whose
    /// `autoFillEnabledRefreshHandler` AppRootView installed. Passed in by the
    /// database list's settings sheet and the macOS Settings scene so the
    /// per-database AutoFill toggles hit that hook. Contexts that cannot reach
    /// it (the open-database App Settings sheet) leave it nil and get the
    /// fallback below.
    var listViewModel: DatabaseListViewModel? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var autoLockTimeout = SettingsService.autoLockTimeout
    @State private var lockOnBackground = SettingsService.lockOnBackground
    @State private var clipboardTimeout = SettingsService.clipboardTimeout
    @State private var autoUnlockWithFaceID = SettingsService.autoUnlockWithFaceID
    @State private var showWebsiteIcons = SettingsService.showWebsiteIcons
    @State private var showDatabaseUsageStats = SettingsService.showDatabaseUsageStats
    @State private var appearanceMode = SettingsService.appearanceMode
    @State private var quickAutoFillEnabled = SettingsService.quickAutoFillEnabled
    @State private var sortOrder = DatabaseViewModel.savedSortOrder()
    @State private var sortAscending = DatabaseViewModel.savedSortAscending()
    @State private var cloudAccounts = CloudAccountStore.accounts
    @State private var pendingCloudAccountSignOut: CloudAccount?
    @State private var feedbackContext: FeedbackComposerContext?
    @State private var macLockPolicy = SettingsService.macLockPolicy
    @State private var blockScreenCapture = SettingsService.blockScreenCapture
    @State private var fallbackListViewModel: DatabaseListViewModel?

    var body: some View {
        Group {
            #if os(macOS)
            macSettingsLayout
            #else
            iosSettingsLayout
            #endif
        }
        .preferredColorScheme(preferredColorScheme)
        .sheet(item: $feedbackContext) { context in
            FeedbackComposerView(context: context)
        }
    }

    #if os(macOS)
    /// Settings-window layout: the standard macOS tabbed settings shape,
    /// shown by the `Settings { }` scene (⌘,) and by in-app settings sheets.
    private var macSettingsLayout: some View {
        applyingChangeHandlers(macSettingsTabs)
            .frame(minWidth: 560, minHeight: 480)
    }

    private var macSettingsTabs: some View {
        TabView {
            MacSecuritySettingsTab(
                autoLockTimeout: $autoLockTimeout,
                macLockPolicy: $macLockPolicy,
                clipboardTimeout: $clipboardTimeout,
                autoUnlockWithBiometrics: $autoUnlockWithFaceID,
                blockScreenCapture: $blockScreenCapture
            )
            .tabItem {
                Label("Security", systemImage: "lock.shield")
            }
            .accessibilityIdentifier("settings.tab.security")

            MacDisplaySettingsTab(
                showWebsiteIcons: $showWebsiteIcons,
                showDatabaseUsageStats: $showDatabaseUsageStats,
                appearanceMode: $appearanceMode,
                sortOrder: $sortOrder,
                sortAscending: $sortAscending
            )
            .tabItem {
                Label("Display", systemImage: "eye")
            }
            .accessibilityIdentifier("settings.tab.display")

            Form {
                cloudAccountsSection
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Cloud", systemImage: "icloud")
            }
            .accessibilityIdentifier("settings.tab.cloud")

            NavigationStack {
                Form {
                    feedbackSection
                    TipJarView()
                    AboutSectionContent()
                }
                .formStyle(.grouped)
            }
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
            .accessibilityIdentifier("settings.tab.about")
        }
    }
    #else
    private var iosSettingsLayout: some View {
        NavigationStack {
            applyingChangeHandlers(
                Form {
                    settingsNavigationSection
                    cloudAccountsSection
                    feedbackSection
                    TipJarView()
                    aboutNavigationSection
                }
            )
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    #endif

    /// Shared persistence handlers applied to both the iOS and macOS layouts.
    private func applyingChangeHandlers(_ content: some View) -> some View {
        content
            .onChange(of: autoLockTimeout) { _, newValue in
                SettingsService.autoLockTimeout = newValue
                viewModel?.resetInactivityTimer()
            }
            .onChange(of: lockOnBackground) { _, newValue in
                SettingsService.lockOnBackground = newValue
            }
            .onChange(of: macLockPolicy) { _, newValue in
                SettingsService.macLockPolicy = newValue
            }
            .onChange(of: blockScreenCapture) { _, newValue in
                SettingsService.blockScreenCapture = newValue
                #if os(macOS)
                // Tell the live screen-protection service to re-apply the
                // capture policy to already-open windows immediately.
                NotificationCenter.default.post(
                    name: ScreenProtectionService.captureBlockingDidChangeNotification,
                    object: nil
                )
                #endif
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
            .onChange(of: appearanceMode) { _, newValue in
                SettingsService.appearanceMode = newValue
            }
            .onChange(of: quickAutoFillEnabled) { _, newValue in
                SettingsService.quickAutoFillEnabled = newValue
                if newValue {
                    // Global toggle back on: refresh the currently unlocked
                    // database immediately (the main app has at most one open
                    // session — `viewModel` — so this is "every currently
                    // unlocked enabled database"). No per-database gate is
                    // needed here: `populateCredentialStoreIfUnlocked`
                    // re-reads the registry and no-ops when that database has
                    // AutoFill disabled, so a disabled database's entries are
                    // never published. Every other enabled database
                    // repopulates lazily on its next unlock.
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
                installFallbackListViewModelIfNeeded()
            }
    }

    private var resolvedListViewModel: DatabaseListViewModel? {
        listViewModel ?? fallbackListViewModel
    }

    /// The AutoFill settings screen must toggle databases through the app's
    /// `DatabaseListViewModel` so `setAutoFillEnabled` runs the
    /// `autoFillEnabledRefreshHandler` hook (immediate republish when the
    /// toggled database is the currently unlocked session). The open-database
    /// App Settings sheet (`DatabaseSettingsView` in `GroupListView.swift`)
    /// cannot reach that instance through the view hierarchy, so this creates
    /// a local list view model and installs the same bridge `AppRootView`
    /// installs — against the session `viewModel` this sheet was opened with,
    /// which is the app's only unlocked database, so the behavior is
    /// identical.
    private func installFallbackListViewModelIfNeeded() {
        guard listViewModel == nil, fallbackListViewModel == nil else { return }
        let fallback = DatabaseListViewModel()
        let sessionViewModel = viewModel
        fallback.autoFillEnabledRefreshHandler = { databaseID in
            guard let sessionViewModel,
                  sessionViewModel.databaseReference.id == databaseID else { return }
            sessionViewModel.populateCredentialStoreIfUnlocked()
        }
        fallbackListViewModel = fallback
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
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
                if let resolvedListViewModel {
                    AutoFillSettingsView(
                        quickAutoFillEnabled: $quickAutoFillEnabled,
                        listViewModel: resolvedListViewModel
                    )
                }
            } label: {
                Label("AutoFill", systemImage: "text.cursor")
            }
            .accessibilityIdentifier("settings.autofill.link")

            NavigationLink {
                DisplaySettingsView(
                    showWebsiteIcons: $showWebsiteIcons,
                    showDatabaseUsageStats: $showDatabaseUsageStats,
                    appearanceMode: $appearanceMode,
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
                            CloudProviderIcon(provider: account.providerKind)
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
            if cloudAccounts.isEmpty == false {
                Text("Signing out disconnects future syncs but keeps cached cloud databases available until you remove them.")
            }
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
                        Text(option.title).tag(option)
                    }
                }

                Picker("Clipboard Clear Timeout", selection: $clipboardTimeout) {
                    ForEach(SettingsService.ClipboardTimeout.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
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
    /// The app's shared list view model (or `SettingsView`'s fallback bridge).
    /// All per-database toggles must go through its `setAutoFillEnabled` —
    /// never `DatabaseListStore` directly — so disabling does targeted
    /// identity removal and enabling republishes the open session immediately
    /// via the installed `autoFillEnabledRefreshHandler`.
    let listViewModel: DatabaseListViewModel
    @State private var isProviderEnabled: Bool?
    @State private var isClearEntriesConfirmationPresented = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            providerSection

            Section {
                Toggle("Quick AutoFill", isOn: $quickAutoFillEnabled)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("KeeForge suggests credentials from the databases selected below.")

                    if quickAutoFillEnabled {
                        Text("Credential suggestions appear in the keyboard bar. Requires Face ID to unlock when tapped.")
                    }
                }
            }

            databasesSection
            clearEntriesSection
        }
        .navigationTitle("AutoFill")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            listViewModel.reload()
        }
        .task {
            isProviderEnabled = await AutoFillStatusService.isAutoFillEnabled()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { isProviderEnabled = await AutoFillStatusService.isAutoFillEnabled() }
            }
        }
    }

    private var databasesSection: some View {
        Section {
            if listViewModel.databases.isEmpty {
                Text("No databases added yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(listViewModel.databases) { reference in
                    Toggle(
                        reference.displayName,
                        isOn: Binding(
                            get: { currentReference(for: reference).autoFillEnabled },
                            set: { listViewModel.setAutoFillEnabled($0, for: reference) }
                        )
                    )
                    .accessibilityIdentifier("settings.autofill.database-toggle.\(reference.id.uuidString)")
                }
            }
        } header: {
            Text("Databases")
        } footer: {
            if quickAutoFillEnabled,
               listViewModel.databases.contains(where: { $0.autoFillEnabled }) == false {
                Text("AutoFill is on, but no databases are selected.")
            }
        }
    }

    private var clearEntriesSection: some View {
        Section {
            Button("Clear AutoFill Entries", role: .destructive) {
                isClearEntriesConfirmationPresented = true
            }
            .accessibilityIdentifier("settings.autofill.clear-entries")
            .confirmationDialog(
                "Clear AutoFill Entries?",
                isPresented: $isClearEntriesConfirmationPresented
            ) {
                // Deliberately no republish of the currently open database
                // after clearing: the user asked for an empty store now.
                // Suggestions rebuild as enabled databases are next unlocked.
                Button("Clear Entries", role: .destructive) {
                    CredentialIdentityStoreManager.clearStore()
                }
                .accessibilityIdentifier("settings.autofill.clear-entries.confirm")

                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all suggestions from AutoFill. Suggestions return the next time you unlock each database that has AutoFill turned on.")
            }
        }
    }

    private func currentReference(for reference: DatabaseReference) -> DatabaseReference {
        listViewModel.databases.first(where: { $0.id == reference.id }) ?? reference
    }

    private var providerSection: some View {
        Section {
            LabeledContent("AutoFill in iOS", value: providerStatusText)

            if isProviderEnabled == false {
                Button("Turn On AutoFill") {
                    Task {
                        if await AutoFillStatusService.requestEnableAutoFill() == true {
                            isProviderEnabled = true
                        }
                    }
                }
                .accessibilityIdentifier("settings.autofill.turn-on")
            } else {
                Button("Open iOS AutoFill Settings") {
                    Task { await AutoFillStatusService.openAutoFillSettings() }
                }
                .accessibilityIdentifier("settings.autofill.open-ios-settings")
            }
        } footer: {
            if isProviderEnabled == false {
                Text("KeeForge isn't enabled as an AutoFill provider yet. Turn it on to fill passwords in Safari and other apps.")
            } else if isProviderEnabled == true {
                Text("KeeForge is enabled as an AutoFill provider.")
            }
        }
    }

    private var providerStatusText: String {
        guard let isProviderEnabled else { return "—" }
        return isProviderEnabled ? "On" : "Off"
    }
}

private struct DisplaySettingsView: View {
    @Binding var showWebsiteIcons: Bool
    @Binding var showDatabaseUsageStats: Bool
    @Binding var appearanceMode: SettingsService.AppearanceMode
    @Binding var sortOrder: DatabaseViewModel.SortOrder
    @Binding var sortAscending: Bool

    var body: some View {
        Form {
            themeSection
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

    private var themeSection: some View {
        Section {
            Picker("Theme", selection: $appearanceMode) {
                ForEach(SettingsService.AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .accessibilityIdentifier("settings.display.theme-picker")
        }
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
                    Text(order.title).tag(order)
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
            AboutSectionContent()
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutSectionContent: View {
    var body: some View {
        aboutSection
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: "KeeForge")

            LabeledContent("Version", value: appVersion)

            Link(destination: URL(string: "mailto:support@keeforge.com")!) {
                Label("Contact Support", systemImage: "envelope")
            }

            Link(destination: URL(string: "https://github.com/KeeForge/KeeForge/issues")!) {
                Label("Report a Bug", systemImage: "ladybug")
            }

            Link(destination: URL(string: "https://github.com/KeeForge/KeeForge")!) {
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

#if os(macOS)

// MARK: - macOS settings tabs

private struct MacSecuritySettingsTab: View {
    @Binding var autoLockTimeout: SettingsService.AutoLockTimeout
    @Binding var macLockPolicy: SettingsService.MacLockPolicy
    @Binding var clipboardTimeout: SettingsService.ClipboardTimeout
    @Binding var autoUnlockWithBiometrics: Bool
    @Binding var blockScreenCapture: Bool

    var body: some View {
        Form {
            Section {
                Picker("Lock Automatically", selection: $macLockPolicy) {
                    ForEach(SettingsService.MacLockPolicy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .accessibilityIdentifier("settings.lock-policy.picker")

                Picker("Auto-Lock Timeout", selection: $autoLockTimeout) {
                    ForEach(SettingsService.AutoLockTimeout.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }

                if BiometricService.isAvailable {
                    Toggle("Auto-Unlock with Touch ID", isOn: $autoUnlockWithBiometrics)
                }
            } footer: {
                Text("KeeForge always locks on screen lock, screensaver, system sleep, and user switching. The stricter option also locks whenever another app becomes active.")
            }

            Section {
                Toggle("Block Screen Capture", isOn: $blockScreenCapture)
                    .accessibilityIdentifier("settings.block-screen-capture.toggle")
            } header: {
                Text("Screen Privacy")
            } footer: {
                Text("Asks macOS to exclude KeeForge's windows from screenshots and screen recordings. This is best-effort: on macOS 15 and later, ScreenCaptureKit-based recorders can capture the window anyway. When it works, a screenshot of KeeForge comes out black or fails — that is the protection doing its job. Regardless of this setting, KeeForge blurs its windows whenever it loses focus.")
            }

            Section {
                Picker("Clipboard Clear Timeout", selection: $clipboardTimeout) {
                    ForEach(SettingsService.ClipboardTimeout.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Copied values are cleared after this timeout (unless you copied something else since) and are hidden from clipboard-manager apps. Unlike iOS, macOS cannot exclude copies from Handoff's Universal Clipboard, so a copied password may briefly appear on your other devices' clipboards.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MacDisplaySettingsTab: View {
    @Binding var showWebsiteIcons: Bool
    @Binding var showDatabaseUsageStats: Bool
    @Binding var appearanceMode: SettingsService.AppearanceMode
    @Binding var sortOrder: DatabaseViewModel.SortOrder
    @Binding var sortAscending: Bool

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearanceMode) {
                    ForEach(SettingsService.AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("settings.display.theme-picker")
            }

            Section {
                Toggle("Show Usage Stats in Database List", isOn: $showDatabaseUsageStats)
                    .accessibilityIdentifier("settings.display.usage-stats-toggle")

                Toggle("Download Website Favicons", isOn: $showWebsiteIcons)
                    .accessibilityIdentifier("settings.display.favicons-toggle")
            } footer: {
                if showWebsiteIcons {
                    Text("Fetches icons from DuckDuckGo. Only the website domain is sent.")
                }
            }

            Section("Entry List") {
                Picker("Default Sort Order", selection: $sortOrder) {
                    ForEach(DatabaseViewModel.SortOrder.allCases, id: \.self) { order in
                        Text(order.title).tag(order)
                    }
                }

                Picker("Sort Direction", selection: $sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
            }

            if showWebsiteIcons {
                Section {
                    Button("Clear Favicon Cache", role: .destructive) {
                        FaviconService.clearCache()
                    }
                    .accessibilityIdentifier("settings.display.clear-favicon-cache")
                }
            }
        }
        .formStyle(.grouped)
    }
}

#endif
