#if os(macOS)
import Foundation
import Observation

@MainActor
protocol BrowserHostInstalling: AnyObject {
    func state(for browser: HostBrowser) -> BrowserHostInstallerState
    func setUp(_ browser: HostBrowser) async throws
    @discardableResult func repairAll() -> [HostBrowser: BrowserHostInstallerState]
    func remove(_ browser: HostBrowser) throws
}

extension BrowserHostInstaller: BrowserHostInstalling {}

/// Settings ▸ Browsers: the bridge switch, installing the native-messaging
/// manifest into each browser on this Mac, and the paired browsers.
@MainActor @Observable
final class MacBrowserBridgeSettingsModel {
    struct HostRow: Identifiable, Equatable {
        let browser: HostBrowser
        let state: BrowserHostInstallerState
        var id: HostBrowser { browser }
        var name: String { browser.displayName }
    }

    struct PairedRow: Identifiable, Equatable {
        let id: String
        let name: String
        let pairedDate: String
        let lastUsed: String
    }

    enum Confirmation: Equatable {
        case remove(clientID: String, name: String)
        case removeAll
    }

    let controller: MacBrowserBridgeController
    @ObservationIgnored private let installer: any BrowserHostInstalling
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let locale: Locale

    private(set) var hostRows: [HostRow] = []
    private(set) var hostErrors: [HostBrowser: BrowserHostInstallerError] = [:]
    /// A browser whose folder panel or file change is in progress; every row's buttons wait for it.
    private(set) var busyBrowser: HostBrowser?
    private(set) var removalFailed = false
    var confirmation: Confirmation?

    init(controller: MacBrowserBridgeController, installer: any BrowserHostInstalling,
         now: @escaping () -> Date = { Date() }, locale: Locale = .autoupdatingCurrent) {
        self.controller = controller
        self.installer = installer
        self.now = now
        self.locale = locale
        refreshHosts()
    }

    var isEnabled: Bool {
        get { controller.isEnabled }
        set { controller.isEnabled = newValue }
    }

    var unavailabilityMessage: String? {
        switch controller.unavailability {
        case .noGroupContainer:
            String(localized: "This copy of KeeForge isn’t signed to let browser extensions connect.")
        case .socketInUse:
            String(localized: "Browser extensions can’t connect because another copy of KeeForge is already serving them.")
        case .bridgeKey:
            String(localized: "Browser extensions can’t connect because KeeForge couldn’t read its browser key from the Keychain.")
        case .failed:
            String(localized: "Browser extensions can’t connect.")
        case nil:
            nil
        }
    }

    var showsPairingFailure: Bool { controller.pairingFailed }

    var pairedRows: [PairedRow] {
        controller.pairedBrowsers.map { browser in
            PairedRow(id: browser.clientID, name: browser.name,
                      pairedDate: browser.pairedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)),
                      lastUsed: lastUsedText(browser.lastUsedAt))
        }
    }

    func lastUsedText(_ date: Date?) -> String {
        guard let date else { return String(localized: "Never used") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return String(localized: "Last used \(formatter.localizedString(for: date, relativeTo: now()))")
    }

    /// Called whenever Settings is shown: rereads the browsers and drops last time's messages.
    func reload() {
        controller.clearPairingFailure()
        hostErrors = [:]
        removalFailed = false
        refreshHosts()
    }

    func refreshHosts() {
        hostRows = HostBrowser.allCases.compactMap { browser in
            let state = installer.state(for: browser)
            return state == .notInstalled ? nil : HostRow(browser: browser, state: state)
        }
    }

    func errorMessage(for browser: HostBrowser) -> String? {
        switch hostErrors[browser] {
        case nil, .grantCancelled: nil
        case .wrongFolder: String(localized: "Choose the folder KeeForge suggests, then click Grant Access.")
        case .browserParentMissing: String(localized: "Open this browser once, then try again.")
        case .accessLost: String(localized: "KeeForge couldn’t reach this browser’s folder. Try again.")
        case .extensionIDNotConfigured: String(localized: "This version of KeeForge can’t set up this browser yet.")
        case .foreignManifest: String(localized: "Another app’s file is in the way, so KeeForge left it unchanged.")
        case .unsafeManifest: String(localized: "KeeForge left this browser’s folder unchanged because something in it isn’t safe to replace.")
        }
    }

    func setUp(_ browser: HostBrowser) async {
        guard busyBrowser == nil else { return }
        busyBrowser = browser
        defer { busyBrowser = nil; refreshHosts() }
        hostErrors[browser] = nil
        do { try await installer.setUp(browser) }
        catch { hostErrors[browser] = Self.installerError(error) }
    }

    /// Rewrites every set-up browser's manifest from its stored folder access, without a panel.
    func repair(_ browser: HostBrowser) {
        guard busyBrowser == nil else { return }
        hostErrors[browser] = nil
        installer.repairAll()
        refreshHosts()
        if hostRows.first(where: { $0.browser == browser })?.state == .needsRepair {
            hostErrors[browser] = .accessLost
        }
    }

    func removeHost(_ browser: HostBrowser) {
        guard busyBrowser == nil else { return }
        hostErrors[browser] = nil
        do { try installer.remove(browser) }
        catch { hostErrors[browser] = Self.installerError(error) }
        refreshHosts()
    }

    func requestRemove(_ row: PairedRow) {
        confirmation = .remove(clientID: row.id, name: row.name)
    }

    func requestRemoveAll() {
        confirmation = .removeAll
    }

    /// Runs the confirmed removal; the view calls it only from the confirmation's destructive button.
    func confirm() async {
        guard let confirmation else { return }
        self.confirmation = nil
        removalFailed = false
        do {
            switch confirmation {
            case .remove(let clientID, _): try await controller.removeBrowser(clientID: clientID)
            case .removeAll: try await controller.removeAllBrowsers()
            }
        } catch {
            removalFailed = true
        }
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    private static func installerError(_ error: any Error) -> BrowserHostInstallerError {
        // Other failures come from the file system or the bookmark; the folder could not be changed.
        (error as? BrowserHostInstallerError) ?? .accessLost
    }
}
#endif
