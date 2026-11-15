#if os(macOS)
import AppKit
import SwiftUI

struct MacSecuritySettingsTab: View {
    @Bindable var settings: AppSettingsViewModel

    var body: some View {
        Form {
            LabeledContent("Lock databases:") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("When the screen locks or the Mac sleeps", isOn: .constant(true))
                        .disabled(true)
                        .accessibilityIdentifier("settings.security.screen-lock-toggle")
                    HStack {
                        Toggle("When KeeForge is in the background for", isOn: Binding(
                            get: { settings.macLockPolicy == .appDeactivates },
                            set: { settings.macLockPolicy = $0 ? .appDeactivates : .screenLockOrSleep }
                        ))
                        .accessibilityIdentifier("settings.lock-policy.picker")
                        Picker("Background lock delay", selection: $settings.macBackgroundLockDelay) {
                            ForEach(SettingsService.MacBackgroundLockDelay.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .disabled(settings.macLockPolicy != .appDeactivates)
                        .accessibilityIdentifier("settings.security.background-delay-picker")
                    }
                    caption("Locked windows stay open and show the unlock screen.")
                }
            }
            LabeledContent("Auto-lock:") {
                HStack {
                    let timed = settings.autoLockTimeout != .immediately && settings.autoLockTimeout != .never
                    if timed { Text("After") }
                    Picker("Auto-Lock Timeout", selection: $settings.autoLockTimeout) {
                        ForEach(SettingsService.AutoLockTimeout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize()
                    if timed { Text("of inactivity") }
                }
            }
            Divider()
            LabeledContent("Unlock with Touch ID:") {
                VStack(alignment: .leading, spacing: 8) {
                    if BiometricService.isAvailable {
                        Toggle("Auto-Unlock with Touch ID", isOn: $settings.autoUnlockWithFaceID)
                            .accessibilityIdentifier("settings.security.auto-unlock-toggle")
                        caption("Automatically prompt when opening a database or returning to its locked window. This setting also applies to AutoFill.")
                    }
                    Picker("Ask for the master password:", selection: $settings.quickUnlockPasswordInterval) {
                        ForEach(SettingsService.QuickUnlockPasswordInterval.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("settings.security.require-password-picker")
                    caption("Touch ID and Apple Watch stop unlocking a database this long after its master password was last entered, until you enter it again. With Always, KeeForge saves no unlock key and asks for the master password every time. This also applies to AutoFill.")
                }
            }
            Divider()
            LabeledContent("Clear clipboard:") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Clipboard Clear Timeout", selection: $settings.clipboardTimeout) {
                        ForEach(SettingsService.ClipboardTimeout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden()
                    caption("Copied values are cleared after this timeout (unless you copied something else since) and are hidden from clipboard-manager apps. Unlike iOS, macOS cannot exclude copies from Handoff's Universal Clipboard, so a copied password may briefly appear on your other devices' clipboards.")
                }
            }
            Divider()
            LabeledContent("Screen capture:") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Hide database windows from screen recording and screenshots", isOn: $settings.blockScreenCapture)
                        .accessibilityIdentifier("settings.block-screen-capture.toggle")
                    caption("Asks macOS to exclude KeeForge's windows from screenshots and screen recordings. This is best-effort: on macOS 15 and later, ScreenCaptureKit-based recorders can capture the window anyway. When it works, a screenshot of KeeForge comes out black or fails — that is the protection doing its job. Regardless of this setting, KeeForge blurs its windows whenever it loses focus.")
                }
            }
            Divider()
            LabeledContent("Reveal and copy:") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Authentication Grace Period", selection: $settings.authenticationGracePeriod) {
                        ForEach(SettingsService.AuthenticationGracePeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden()
                        .accessibilityIdentifier("settings.security.authentication-grace-picker")
                    caption("After you unlock a database or authenticate, passwords and protected fields can be shown and copied for this long without asking again. Locking the database ends it. AutoFill is not affected.")
                }
            }
        }
        .formStyle(.columns).padding(24)
    }
}

struct MacGeneralSettingsTab: View {
    @Bindable var settings: AppSettingsViewModel

    var body: some View {
        Form {
            Picker("Default sort order:", selection: $settings.sortOrder) {
                ForEach(DatabaseViewModel.SortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent("Sort direction:") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Sort Direction", selection: $settings.sortAscending) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }.labelsHidden()
                    caption("New database windows start with this order. Title, Date Created or Date Modified.")
                }
            }
            Divider()
            LabeledContent("Databases window:") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show Usage Stats in Database List", isOn: $settings.showDatabaseUsageStats)
                        .accessibilityIdentifier("settings.display.usage-stats-toggle")
                    caption("When off, KeeForge hides last-opened activity from the locked database list.")
                }
            }
            Divider()
            LabeledContent("Website icons:") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Download Website Favicons", isOn: $settings.showWebsiteIcons)
                        .accessibilityIdentifier("settings.display.favicons-toggle")
                    caption("Fetches icons from DuckDuckGo. Only the website domain is sent.")
                    if settings.showWebsiteIcons {
                        Button("Clear Favicon Cache", action: settings.clearFaviconCache)
                            .accessibilityIdentifier("settings.display.clear-favicon-cache")
                    }
                }
            }
            Divider()
            LabeledContent("After updates:") {
                Toggle("Show What's New After Updates", isOn: $settings.showWhatsNewAfterUpdates)
                    .accessibilityIdentifier("settings.display.whats-new-toggle")
            }
        }.formStyle(.columns).padding(24)
    }
}

struct MacAppearanceSettingsTab: View {
    @Bindable var settings: AppSettingsViewModel

    var body: some View {
        Form {
            LabeledContent("Theme:") {
                HStack(spacing: 12) {
                    ForEach(SettingsService.AppearanceMode.allCases, id: \.self) { mode in
                        Button { settings.appearanceMode = mode } label: {
                            VStack(spacing: 8) {
                                HStack(spacing: 0) {
                                    if mode != .dark { themeSample(dark: false) }
                                    if mode != .light { themeSample(dark: true) }
                                }
                                .frame(width: 84, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(settings.appearanceMode == mode ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 2))
                                .accessibilityHidden(true)
                                Text(mode.title)
                            }
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(settings.appearanceMode == mode ? .isSelected : [])
                    }
                }
                .accessibilityRepresentation {
                    Picker("Theme", selection: $settings.appearanceMode) {
                        ForEach(SettingsService.AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.radioGroup)
                }
                .accessibilityIdentifier("settings.display.theme-picker")
                // Puts the row label beside the middle of the 54 pt thumbnails, not their captions.
                .alignmentGuide(.firstTextBaseline) { _ in 54 / 2 + 4 }
            }
            Divider()
            LabeledContent("Accent color:") {
                VStack(alignment: .leading, spacing: 8) {
                    ColorPicker("Accent Color", selection: Binding(
                        get: { settings.appAccentColor?.color ?? Color("AccentColor") },
                        set: { settings.appAccentColor = .init(color: $0) }
                    ), supportsOpacity: false).labelsHidden()
                        .accessibilityIdentifier("settings.display.accent-color-picker")
                    Button("Use Default Accent Color") { settings.appAccentColor = nil }
                        .disabled(settings.appAccentColor == nil)
                        .accessibilityIdentifier("settings.display.accent-color-reset")
                    caption("Tints buttons, selection and links in every KeeForge window. The default follows KeeForge blue.")
                }
            }
        }.formStyle(.columns).padding(24)
    }
    private func themeSample(dark: Bool) -> some View {
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: .controlBackgroundColor)).frame(height: 14)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

}

struct MacAutoFillSettingsTab: View {
    @Bindable var settings: AppSettingsViewModel
    let listViewModel: DatabaseListViewModel
    let clearEntries: () -> Void

    var body: some View {
        Form {
            LabeledContent("AutoFill in macOS:") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle().fill(listViewModel.isAutoFillProviderEnabled == true ? .green : .secondary).frame(width: 7, height: 7)
                        Text(listViewModel.isAutoFillProviderEnabled.map { $0 ? String(localized: "On") : String(localized: "Off") } ?? "—")
                    }.accessibilityIdentifier("settings.autofill.provider-status")
                    if listViewModel.isAutoFillProviderEnabled == true {
                        caption("KeeForge is enabled as an AutoFill provider.")
                    } else if listViewModel.isAutoFillProviderEnabled == false {
                        Button("Turn On AutoFill") { Task { await listViewModel.requestEnableAutoFill() } }
                            .accessibilityIdentifier("settings.autofill.turn-on")
                        if listViewModel.isAutoFillEnableRequestRejected {
                            caption("The last attempt did not turn it on. Open AutoFill Settings and enable KeeForge there.")
                        }
                    }
                    Button("Open AutoFill Settings…") { Task { await AutoFillStatusService.openAutoFillSettings() } }
                        .accessibilityIdentifier("settings.autofill.open-mac-settings")
                }
            }
            Divider()
            LabeledContent("Suggestions:") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Quick AutoFill", isOn: $settings.quickAutoFillEnabled)
                    caption("KeeForge suggests credentials from the databases selected below when macOS offers to fill a password. Authentication is required when you choose a suggestion.")
                }
            }
            Divider()
            LabeledContent("Databases:") {
                VStack(alignment: .leading, spacing: 8) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            if listViewModel.databases.isEmpty { Text("No databases added yet").foregroundStyle(.secondary) }
                            ForEach(listViewModel.databases) { reference in
                                Toggle(isOn: Binding(
                                    get: { listViewModel.databases.first { $0.id == reference.id }?.autoFillEnabled ?? false },
                                    set: { listViewModel.setAutoFillEnabled($0, for: reference) }
                                )) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: reference.displayName)
                                        Text(verbatim: MacLockedDatabaseSummary.fileAndStorage(for: reference))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.accessibilityIdentifier("settings.autofill.database-toggle.\(reference.id.uuidString)")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if listViewModel.isAutoFillProviderEnabled == false {
                        caption("These selections only take effect once KeeForge is enabled as an AutoFill provider above.")
                    }
                    if settings.quickAutoFillEnabled, !listViewModel.databases.contains(where: \.autoFillEnabled) {
                        caption("AutoFill is on, but no databases are selected.")
                    }
                    if settings.quickAutoFillEnabled, listViewModel.isAutoFillLimitedToOneDatabase {
                        caption("macOS shows suggestions from one database at a time — whichever you unlocked most recently. Unlock another selected database to switch which entries appear.")
                    }
                    Button("Clear AutoFill Entries…", action: clearEntries)
                        .accessibilityIdentifier("settings.autofill.clear-entries")
                    caption("This removes all suggestions from AutoFill. Suggestions return the next time you unlock each database that has AutoFill turned on.")
                }
            }
        }.formStyle(.columns).padding(24)
            .onAppear { listViewModel.reload() }
            .task { await listViewModel.refreshAutoFillStatus() }
            .onAppDidBecomeActive { Task { await listViewModel.refreshAutoFillStatus() } }
    }
}

struct MacServersSettingsTab: View {
    let settings: AppSettingsViewModel
    let disconnect: (CloudAccount) -> Void

    var body: some View {
        Form {
            LabeledContent("Servers:") {
                VStack(alignment: .leading, spacing: 8) {
                    if settings.macServerAccounts.isEmpty {
                        GroupBox {
                            Text("No servers connected").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        caption("Use Connect to Server in the Databases window to add one.")
                    } else {
                        GroupBox {
                            VStack(spacing: 12) {
                                ForEach(settings.macServerAccounts) { account in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: account.displayName)
                                                .accessibilityIdentifier("settings.cloud.account.label")
                                            Text(account.providerKind?.displayName ?? account.provider).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Sign Out") { disconnect(account) }
                                            .accessibilityIdentifier("settings.cloud.signout.button")
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityLabel("Cloud Accounts")
                        caption("Signing out stops future syncs but keeps cached databases available until you remove them.")
                    }
                }
            }
        }.formStyle(.columns).padding(24)
    }
}

struct MacAboutSettingsTab: View {
    let acknowledgments: () -> Void
    @State private var feedbackContext: FeedbackComposerContext?

    static var includesUpdates: Bool {
        #if KEEFORGE_DIRECT_DOWNLOAD
        true
        #else
        false
        #endif
    }

    var body: some View {
        Form {
            LabeledContent {
                VStack(alignment: .leading, spacing: 4) {
                    Text("KeeForge").font(.title.bold())
                    Text("Version \(version)").foregroundStyle(.secondary)
                }
            } label: {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 64, height: 64)
            }
            Divider()
            #if KEEFORGE_DIRECT_DOWNLOAD
            MacSoftwareUpdateSettingsGroup()
            Divider()
            #endif
            LabeledContent("Feedback:") {
                Button("Send Feedback") { feedbackContext = .general }
                    .accessibilityIdentifier("settings.send-feedback")
            }
            #if KEEFORGE_DIRECT_DOWNLOAD
            LabeledContent("Support KeeForge:") {
                VStack(alignment: .leading, spacing: 8) {
                    if let url = URL(string: "https://github.com/sponsors/crazytan") {
                        Link("Sponsor KeeForge", destination: url).accessibilityIdentifier("support.sponsors")
                    }
                    caption("KeeForge is free and open source. Sponsorship covers the Apple Developer Program and the time that goes into it.")
                }
            }
            #else
            LabeledContent("Support KeeForge:") {
                VStack(alignment: .leading, spacing: 8) { TipJarView() }
            }
            #endif
            Divider()
            LabeledContent("Links:") {
                VStack(alignment: .leading, spacing: 8) {
                    aboutLink("Contact Support", "mailto:support@keeforge.com")
                    aboutLink("Report a Bug", "https://github.com/KeeForge/KeeForge/issues")
                    aboutLink("Source Code", "https://github.com/KeeForge/KeeForge")
                    Button("Acknowledgments…", action: acknowledgments)
                }
            }
        }.formStyle(.columns).padding(24)
            .sheet(item: $feedbackContext) { FeedbackComposerView(context: $0) }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let commit = Bundle.main.object(forInfoDictionaryKey: "GITCommitHash") as? String ?? "dev"
        return "\(short) (\(commit))"
    }

    @ViewBuilder private func aboutLink(_ title: LocalizedStringKey, _ address: String) -> some View {
        if let url = URL(string: address) { Link(title, destination: url) }
    }
}

#if KEEFORGE_DIRECT_DOWNLOAD
private struct MacSoftwareUpdateSettingsGroup: View {
    @Bindable private var service = SoftwareUpdateService.shared

    var body: some View {
        LabeledContent("Updates:") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Automatically Check for Updates", isOn: $service.automaticallyChecksForUpdates)
                    .accessibilityIdentifier("settings.updates.automatic-checks")
                CheckForUpdatesCommand().accessibilityIdentifier("settings.updates.check-now")
            }
        }
    }
}
#endif

private func caption(_ text: LocalizedStringKey) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
}
#endif
