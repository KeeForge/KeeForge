#if os(macOS)
import AppKit
import SwiftUI

/// One label column and one control column for every Settings tab, sized by the window controller.
enum MacSettingsLayout {
    static let windowWidth: CGFloat = 760
    static let insets = EdgeInsets(top: 24, leading: 32, bottom: 28, trailing: 32)
    static let minimumLabelWidth: CGFloat = 170
    /// Longer labels wrap instead of pushing the control column out of the window.
    static let maximumLabelWidth: CGFloat = 240
    static let columnSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 18
    static let itemSpacing: CGFloat = 6
    /// Lines a caption up with the title of the checkbox above it.
    static let checkboxIndent: CGFloat = 20
    static let minimumHeight: CGFloat = 120
    static let maximumHeight: CGFloat = 680

    static func contentSize(forContentHeight height: CGFloat) -> NSSize {
        NSSize(width: windowWidth, height: min(max(height.rounded(.up), minimumHeight), maximumHeight))
    }
}

/// Scrolls only when a tab outgrows `MacSettingsLayout.maximumHeight`; reports its natural height.
struct MacSettingsPane<Content: View>: View {
    let onHeightChange: (CGFloat) -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .padding(MacSettingsLayout.insets)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        }
    }
}

struct MacSettingsForm<Content: View>: View {
    /// Sheets with a fixed height use a tighter rhythm than the Settings window.
    var rowSpacing = MacSettingsLayout.rowSpacing
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: MacSettingsLayout.columnSpacing,
             verticalSpacing: rowSpacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A right-aligned label beside a leading column of controls and their captions.
struct MacSettingsRow<Label: View, Content: View>: View {
    let label: Label?
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) where Label == Text {
        label = Text(title)
        self.content = content()
    }

    /// A row with no label, for an action that belongs to the group above it.
    init(@ViewBuilder content: () -> Content) where Label == Text {
        label = nil
        self.content = content()
    }

    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.content = content()
    }

    var body: some View {
        GridRow {
            Group {
                if let label {
                    label
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            // Takes the label's own width, capped, so the column is only as wide as its longest label.
            .frame(maxWidth: MacSettingsLayout.maximumLabelWidth, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: MacSettingsLayout.minimumLabelWidth, alignment: .trailing)
            .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: MacSettingsLayout.itemSpacing) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Separates groups of rows; spans both columns.
struct MacSettingsSeparator: View {
    var body: some View { Divider().gridCellUnsizedAxes(.horizontal) }
}

extension View {
    /// A pop-up sized to its longest option rather than to the control column.
    func macSettingsPopUp() -> some View { labelsHidden().fixedSize() }
}

struct MacSecuritySettingsTab: View {
    @Bindable var settings: AppSettingsViewModel

    var body: some View {
        MacSettingsForm {
            MacSettingsRow("Lock databases:") {
                Toggle("When the screen locks or the Mac sleeps", isOn: .constant(true))
                    .disabled(true)
                    .accessibilityIdentifier("settings.security.screen-lock-toggle")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { settings.macLockPolicy == .appDeactivates },
                        set: { settings.macLockPolicy = $0 ? .appDeactivates : .screenLockOrSleep }
                    )) {
                        Text("When KeeForge is in the background for").fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("settings.lock-policy.picker")
                    Picker("Background lock delay", selection: $settings.macBackgroundLockDelay) {
                        ForEach(SettingsService.MacBackgroundLockDelay.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .macSettingsPopUp()
                    .disabled(settings.macLockPolicy != .appDeactivates)
                    .accessibilityIdentifier("settings.security.background-delay-picker")
                }
                settingsCaption("Locked windows stay open and show the unlock screen.", indented: true)
            }
            MacSettingsRow("Auto-lock:") {
                Picker("Auto-Lock Timeout", selection: $settings.autoLockTimeout) {
                    ForEach(SettingsService.AutoLockTimeout.allCases, id: \.self) { Text($0.title).tag($0) }
                }.macSettingsPopUp()
            }
            MacSettingsSeparator()
            MacSettingsRow("Unlock with Touch ID:") {
                if BiometricService.isAvailable {
                    Toggle("Auto-Unlock with Touch ID", isOn: $settings.autoUnlockWithFaceID)
                        .accessibilityIdentifier("settings.security.auto-unlock-toggle")
                    settingsCaption("Automatically prompt when opening a database or returning to its locked window. This setting also applies to AutoFill.", indented: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Ask for the master password:")
                    Picker("Ask for the master password:", selection: $settings.quickUnlockPasswordInterval) {
                        ForEach(SettingsService.QuickUnlockPasswordInterval.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .macSettingsPopUp()
                    .accessibilityIdentifier("settings.security.require-password-picker")
                }
                settingsCaption("Touch ID and Apple Watch stop unlocking a database this long after its master password was last entered, until you enter it again. With Always, KeeForge saves no unlock key and asks for the master password every time. This also applies to AutoFill.")
            }
            MacSettingsSeparator()
            MacSettingsRow("Clear clipboard:") {
                Picker("Clipboard Clear Timeout", selection: $settings.clipboardTimeout) {
                    ForEach(SettingsService.ClipboardTimeout.allCases, id: \.self) { Text($0.title).tag($0) }
                }.macSettingsPopUp()
                settingsCaption("Copied values are cleared after this timeout (unless you copied something else since) and are hidden from clipboard-manager apps. Unlike iOS, macOS cannot exclude copies from Handoff's Universal Clipboard, so a copied password may briefly appear on your other devices' clipboards.")
            }
            MacSettingsSeparator()
            MacSettingsRow("Screen capture:") {
                Toggle(isOn: $settings.blockScreenCapture) {
                    Text("Hide database windows from screen recording and screenshots").fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("settings.block-screen-capture.toggle")
                settingsCaption("Asks macOS to exclude KeeForge's windows from screenshots and screen recordings. This is best-effort: on macOS 15 and later, ScreenCaptureKit-based recorders can capture the window anyway. When it works, a screenshot of KeeForge comes out black or fails — that is the protection doing its job. Regardless of this setting, KeeForge blurs its windows whenever it loses focus.", indented: true)
            }
            MacSettingsSeparator()
            MacSettingsRow("Reveal and copy:") {
                Picker("Authentication Grace Period", selection: $settings.authenticationGracePeriod) {
                    ForEach(SettingsService.AuthenticationGracePeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .macSettingsPopUp()
                .accessibilityIdentifier("settings.security.authentication-grace-picker")
                settingsCaption("After you unlock a database or authenticate, passwords and protected fields can be shown and copied for this long without asking again. Locking the database ends it. AutoFill is not affected.")
            }
        }
    }
}

struct MacGeneralSettingsTab: View {
    @Bindable var settings: AppSettingsViewModel

    var body: some View {
        MacSettingsForm {
            MacSettingsRow("Default sort order:") {
                Picker("Default sort order:", selection: $settings.sortOrder) {
                    ForEach(DatabaseViewModel.SortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }.macSettingsPopUp()
            }
            MacSettingsRow("Sort direction:") {
                Picker("Sort Direction", selection: $settings.sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }.macSettingsPopUp()
                settingsCaption("New database windows start with this order. Title, Date Created or Date Modified.")
            }
            MacSettingsSeparator()
            MacSettingsRow("Databases window:") {
                Toggle("Show Usage Stats in Database List", isOn: $settings.showDatabaseUsageStats)
                    .accessibilityIdentifier("settings.display.usage-stats-toggle")
                settingsCaption("When off, KeeForge hides last-opened activity from the locked database list.", indented: true)
            }
            MacSettingsRow("Website icons:") {
                Toggle("Download Website Favicons", isOn: $settings.showWebsiteIcons)
                    .accessibilityIdentifier("settings.display.favicons-toggle")
                settingsCaption("Fetches icons from DuckDuckGo. Only the website domain is sent.", indented: true)
                if settings.showWebsiteIcons {
                    Button("Clear Favicon Cache", action: settings.clearFaviconCache)
                        .accessibilityIdentifier("settings.display.clear-favicon-cache")
                        .padding(.leading, MacSettingsLayout.checkboxIndent)
                }
            }
            MacSettingsSeparator()
            MacSettingsRow("After updates:") {
                Toggle("Show What's New After Updates", isOn: $settings.showWhatsNewAfterUpdates)
                    .accessibilityIdentifier("settings.display.whats-new-toggle")
            }
        }
    }
}

struct MacAppearanceSettingsTab: View {
    @Bindable var settings: AppSettingsViewModel

    var body: some View {
        MacSettingsForm {
            MacSettingsRow("Theme:") {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(SettingsService.AppearanceMode.allCases, id: \.self) { mode in
                        let isSelected = settings.appearanceMode == mode
                        Button { settings.appearanceMode = mode } label: {
                            VStack(spacing: 6) {
                                HStack(spacing: 0) {
                                    if mode != .dark { themeSample(dark: false) }
                                    if mode != .light { themeSample(dark: true) }
                                }
                                .frame(width: 84, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2.5 : 1))
                                .accessibilityHidden(true)
                                Text(mode.title)
                                    .font(.caption.weight(isSelected ? .semibold : .regular))
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(width: 100)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .accessibilityRepresentation {
                    Picker("Theme", selection: $settings.appearanceMode) {
                        ForEach(SettingsService.AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.radioGroup)
                }
                .accessibilityIdentifier("settings.display.theme-picker")
                // Lines the row label up with the top of the thumbnails rather than their names.
                .alignmentGuide(.firstTextBaseline) { $0[.top] + NSFont.systemFont(ofSize: NSFont.systemFontSize).ascender }
            }
            MacSettingsSeparator()
            MacSettingsRow("Accent color:") {
                HStack(spacing: 10) {
                    ColorPicker("Accent Color", selection: Binding(
                        get: { settings.appAccentColor?.color ?? Color("AccentColor") },
                        set: { settings.appAccentColor = .init(color: $0) }
                    ), supportsOpacity: false).labelsHidden()
                        .accessibilityIdentifier("settings.display.accent-color-picker")
                    Button("Use Default Accent Color") { settings.appAccentColor = nil }
                        .disabled(settings.appAccentColor == nil)
                        .accessibilityIdentifier("settings.display.accent-color-reset")
                }
                settingsCaption("Tints buttons, selection and links in every KeeForge window. The default follows KeeForge blue.")
            }
        }
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
        MacSettingsForm {
            MacSettingsRow("AutoFill in macOS:") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(listViewModel.isAutoFillProviderEnabled == true ? .green : .secondary).frame(width: 7, height: 7)
                    Text(listViewModel.isAutoFillProviderEnabled.map { $0 ? String(localized: "On") : String(localized: "Off") } ?? "—")
                }.accessibilityIdentifier("settings.autofill.provider-status")
                if listViewModel.isAutoFillProviderEnabled == true {
                    settingsCaption("KeeForge is enabled as an AutoFill provider.")
                } else if listViewModel.isAutoFillProviderEnabled == false {
                    Button("Turn On AutoFill") { Task { await listViewModel.requestEnableAutoFill() } }
                        .accessibilityIdentifier("settings.autofill.turn-on")
                    if listViewModel.isAutoFillEnableRequestRejected {
                        settingsCaption("The last attempt did not turn it on. Open AutoFill Settings and enable KeeForge there.")
                    }
                }
                Button("Open AutoFill Settings…") { Task { await AutoFillStatusService.openAutoFillSettings() } }
                    .accessibilityIdentifier("settings.autofill.open-mac-settings")
            }
            MacSettingsSeparator()
            MacSettingsRow("Suggestions:") {
                Toggle("Quick AutoFill", isOn: $settings.quickAutoFillEnabled)
                settingsCaption("KeeForge suggests credentials from the databases selected below when macOS offers to fill a password. Authentication is required when you choose a suggestion.", indented: true)
            }
            MacSettingsRow("Databases:") {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
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
                    }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
                }
                if listViewModel.isAutoFillProviderEnabled == false {
                    settingsCaption("These selections only take effect once KeeForge is enabled as an AutoFill provider above.")
                }
                if settings.quickAutoFillEnabled, !listViewModel.databases.contains(where: \.autoFillEnabled) {
                    settingsCaption("AutoFill is on, but no databases are selected.")
                }
                if settings.quickAutoFillEnabled, listViewModel.isAutoFillLimitedToOneDatabase {
                    settingsCaption("macOS shows suggestions from one database at a time — whichever you unlocked most recently. Unlock another selected database to switch which entries appear.")
                }
            }
            MacSettingsSeparator()
            MacSettingsRow {
                Button("Clear AutoFill Entries…", action: clearEntries)
                    .accessibilityIdentifier("settings.autofill.clear-entries")
                settingsCaption("This removes all suggestions from AutoFill. Suggestions return the next time you unlock each database that has AutoFill turned on.")
            }
        }
        .onAppear { listViewModel.reload() }
        .task { await listViewModel.refreshAutoFillStatus() }
        .onAppDidBecomeActive { Task { await listViewModel.refreshAutoFillStatus() } }
    }
}

struct MacServersSettingsTab: View {
    let settings: AppSettingsViewModel
    let disconnect: (CloudAccount) -> Void

    var body: some View {
        MacSettingsForm {
            MacSettingsRow("Servers:") {
                if settings.macServerAccounts.isEmpty {
                    GroupBox {
                        Text("No servers connected").foregroundStyle(.secondary)
                            .padding(4).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    settingsCaption("Use Connect to Server in the Databases window to add one.")
                } else {
                    GroupBox {
                        VStack(spacing: 10) {
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
                        }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityLabel("Cloud Accounts")
                    settingsCaption("Signing out stops future syncs but keeps cached databases available until you remove them.")
                }
            }
        }
    }
}

struct MacAboutSettingsTab: View {
    let acknowledgments: () -> Void
    @State private var feedbackContext: FeedbackComposerContext?
    @Environment(\.openURL) private var openURL

    static var includesUpdates: Bool {
        #if KEEFORGE_DIRECT_DOWNLOAD
        true
        #else
        false
        #endif
    }

    var body: some View {
        MacSettingsForm {
            GridRow(alignment: .center) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "KeeForge").font(.title.bold())
                    Text("Version \(version)").foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            MacSettingsSeparator()
            #if KEEFORGE_DIRECT_DOWNLOAD
            MacSoftwareUpdateSettingsGroup()
            MacSettingsSeparator()
            #endif
            MacSettingsRow("Feedback:") {
                Button("Send Feedback") { feedbackContext = .general }
                    .accessibilityIdentifier("settings.send-feedback")
            }
            MacSettingsRow("Support KeeForge:") {
                #if KEEFORGE_DIRECT_DOWNLOAD
                if let url = URL(string: "https://github.com/sponsors/crazytan") {
                    Button("Sponsor KeeForge") { openURL(url) }.accessibilityIdentifier("support.sponsors")
                }
                settingsCaption("KeeForge is free and open source. Sponsorship covers the Apple Developer Program and the time that goes into it.")
                #else
                TipJarView()
                #endif
            }
            MacSettingsSeparator()
            MacSettingsRow("Links:") {
                VStack(alignment: .leading, spacing: 4) {
                    aboutLink("Contact Support", "mailto:support@keeforge.com")
                    aboutLink("Report a Bug", "https://github.com/KeeForge/KeeForge/issues")
                    aboutLink("Source Code", "https://github.com/KeeForge/KeeForge")
                }
            }
            MacSettingsRow {
                Button("Acknowledgments…", action: acknowledgments)
            }
        }
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
        MacSettingsRow("Updates:") {
            Toggle("Automatically Check for Updates", isOn: $service.automaticallyChecksForUpdates)
                .accessibilityIdentifier("settings.updates.automatic-checks")
            CheckForUpdatesCommand().accessibilityIdentifier("settings.updates.check-now")
                .padding(.leading, MacSettingsLayout.checkboxIndent)
        }
    }
}
#endif

/// Secondary text under a control; `indented` lines it up with a checkbox's title.
func settingsCaption(_ text: LocalizedStringKey, indented: Bool = false) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, indented ? MacSettingsLayout.checkboxIndent : 0)
}
#endif
