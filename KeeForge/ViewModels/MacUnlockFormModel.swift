#if os(macOS)
import Foundation
import KDBXKit
import Observation

/// The session operations a Mac unlock form drives.
@MainActor
protocol MacUnlockSession: AnyObject {
    var state: DatabaseViewModel.State { get }
    var biometricUnlockAvailability: DatabaseViewModel.BiometricUnlockAvailability { get }
    var canRelinkDatabaseFile: Bool { get }
    var keyFileAssociation: MacKeyFileAssociation? { get }
    var hardwareKey: HardwareKeyConfiguration? { get }
    var availableHardwareKeyTransports: [HardwareKeyConfiguration.Transport] { get }
    func setHardwareKey(_ hardwareKey: HardwareKeyConfiguration?) async -> DatabaseListStore.HardwarePreferenceOutcome
    func unlock(password: String, keyFileData: Data?) async
    func unlockWithBiometrics() async -> DatabaseViewModel.BiometricUnlockOutcome
    func loadAssociatedKeyFile() async -> (data: Data, filename: String)?
    func relinkDatabaseFile(to url: URL) throws
    func dismissOpenFailure()
}

extension DatabaseViewModel: MacUnlockSession {
    var keyFileAssociation: MacKeyFileAssociation? {
        MacKeyFileAssociation(reference: databaseReference)
    }
}

/// The reference's key-file association as the unlock form compares it.
struct MacKeyFileAssociation: Equatable {
    let bookmarkData: Data?
    let filename: String?

    init?(reference: DatabaseReference) {
        guard reference.hasAssociatedKeyFile else { return nil }
        bookmarkData = reference.keyFileBookmarkData
        filename = reference.keyFileFilename
    }
}

/// The open panels a locked database window presents; `nil` when the user cancels.
@MainActor
protocol MacUnlockFilePicking: AnyObject {
    func chooseKeyFile() async -> URL?
    func locateDatabase() async -> URL?
}

/// One database window's unlock form. It outlives the locked, opening and
/// error pages, so a picked key file and the field error survive a wrong
/// attempt.
///
/// The typed password lives only while this form shows it: it leaves the
/// field before any attempt awaits, by password or Touch ID, and is dropped
/// when the window shows a page that can neither show nor clear it.
@MainActor @Observable
final class MacUnlockFormModel {
    enum Layout: Equatable {
        /// Touch ID is the primary control, with Unlock inline in the field.
        case biometricPrimary
        case passwordPrimary
    }

    enum KeyLine: Equatable {
        case none
        /// The database's own key file, offered with Clear (for this attempt) and Change….
        case associated(String)
        /// Picked in this form, offered with Clear and Select….
        case picked(String)
    }

    private struct KeyFile {
        let name: String
        var data: Data
        let isAssociated: Bool
    }

    var password = "" {
        didSet {
            if password != oldValue { showsFieldError = false }
        }
    }
    var isPasswordVisible = false
    var selectionAlert: DocumentPickerService.SelectionAlert?
    private(set) var showsFieldError = false
    private(set) var isReconnecting = false
    private(set) var isChangingHardwareKey = false
    /// Bumped when the password field should take focus.
    private(set) var focusRequest = 0
    private var keyFile: KeyFile?
    /// The associated key file was cleared for this attempt; set until unlock, lock or a new association.
    private var declinesAssociation = false
    @ObservationIgnored private var knownAssociation: MacKeyFileAssociation?
    /// Bumped when the association changes, so a read of the old one is dropped.
    @ObservationIgnored private var associationRevision = 0
    /// Bumped by `clearSecrets`, so an await begun before it changes nothing after.
    @ObservationIgnored private var generation = 0

    private let session: any MacUnlockSession
    private let filePicker: any MacUnlockFilePicking
    private let keyFileSelection: UnlockKeyFileSelection

    init(
        session: any MacUnlockSession,
        filePicker: any MacUnlockFilePicking,
        keyFileSelection: UnlockKeyFileSelection = UnlockKeyFileSelection()
    ) {
        self.session = session
        self.filePicker = filePicker
        self.keyFileSelection = keyFileSelection
    }

    var layout: Layout {
        session.biometricUnlockAvailability == .available ? .biometricPrimary : .passwordPrimary
    }

    var showsBiometricUnavailableNote: Bool {
        session.biometricUnlockAvailability == .unavailableWithStoredKey
    }

    var isUnlocking: Bool {
        session.state == .unlocking
    }

    var isLoadingKeyFile: Bool {
        keyFileSelection.isLoading
    }

    /// A YubiKey alone is a valid master key; KeePassXC allows it.
    var canSubmit: Bool {
        (password.isEmpty == false || keyFile != nil || session.hardwareKey != nil)
            && isUnlocking == false && isLoadingKeyFile == false && isChangingHardwareKey == false
    }

    var hardwareKey: HardwareKeyConfiguration? {
        session.hardwareKey
    }

    /// Both slots over USB, plus a stored choice this Mac cannot reach.
    var hardwareKeyOptions: [HardwareKeyConfiguration] {
        HardwareKeyConfiguration.pickerOptions(
            transports: session.availableHardwareKeyTransports,
            current: session.hardwareKey
        )
    }

    /// Whether the form offers the Hardware Key line at all.
    var showsHardwareKey: Bool {
        hardwareKeyOptions.isEmpty == false
    }

    /// Remembered on the database for every later unlock, as on iPhone.
    func setHardwareKey(_ hardwareKey: HardwareKeyConfiguration?) async {
        guard hardwareKey != session.hardwareKey, isUnlocking == false, isChangingHardwareKey == false else { return }
        isChangingHardwareKey = true
        defer { isChangingHardwareKey = false }
        switch await session.setHardwareKey(hardwareKey) {
        case .saved, .unchanged:
            break
        case .rejected, .notPublished:
            selectionAlert = DocumentPickerService.SelectionAlert(
                title: String(localized: "Hardware Key"),
                message: SaveError.saveContextUnavailable.localizedDescription
            )
        case .visibleUnconfirmed, .keyEffectUnconfirmed:
            selectionAlert = DocumentPickerService.SelectionAlert(
                title: String(localized: "Hardware Key"),
                message: CocoaError(.fileWriteUnknown).localizedDescription
            )
        }
    }

    var canUnlockWithBiometrics: Bool {
        layout == .biometricPrimary && isUnlocking == false
    }

    var keyLine: KeyLine {
        guard let keyFile else { return .none }
        return keyFile.isAssociated ? .associated(keyFile.name) : .picked(keyFile.name)
    }

    func submit() async {
        guard canSubmit else { return }
        let password = password
        let keyFileData = keyFile?.data
        self.password = ""
        let generation = generation
        await session.unlock(password: password, keyFileData: keyFileData)
        guard generation == self.generation else { return }
        switch session.state {
        case .unlocked:
            clearSecrets()
        case .error(let failure):
            showsFieldError = failure.isAuthenticationFailure
        case .locked, .unlocking:
            break
        }
    }

    /// Only ever called from the Touch ID button; the form never prompts by itself.
    func unlockWithBiometrics() async {
        guard canUnlockWithBiometrics else { return }
        password = ""
        let generation = generation
        let outcome = await session.unlockWithBiometrics()
        guard generation == self.generation else { return }
        switch outcome {
        case .unlocked:
            clearSecrets()
        case .passwordFallback, .cancelled, .promptUnavailable:
            focusRequest += 1
        case .failed:
            break
        }
    }

    func chooseKeyFile() async {
        guard let url = await filePicker.chooseKeyFile() else { return }
        await useKeyFile(at: url)
    }

    func useKeyFile(at url: URL) async {
        wipeKeyFile()
        let generation = generation
        guard let result = await keyFileSelection.read(url: url), generation == self.generation else { return }
        switch result {
        case .success(let data):
            keyFile = KeyFile(name: url.lastPathComponent, data: data, isAssociated: false)
        case .failure(let error):
            selectionAlert = DocumentPickerService.fileAccessFailureAlert(for: error)
        }
    }

    func clearKeyFile() {
        if keyFile?.isAssociated == true { declinesAssociation = true }
        keyFileSelection.cancel()
        wipeKeyFile()
    }

    /// Never replaces a key file picked in this form, even one picked while the
    /// read was running, nor one cleared for this attempt.
    func loadAssociatedKeyFileIfNeeded() async {
        guard session.state != .unlocked, keyFile == nil, isLoadingKeyFile == false,
              declinesAssociation == false else { return }
        if let uiTestKeyFile = Self.uiTestKeyFile() {
            keyFile = uiTestKeyFile
            return
        }
        let revision = keyFileSelection.revision
        let generation = generation
        let associationRevision = associationRevision
        let association = session.keyFileAssociation
        guard var associated = await session.loadAssociatedKeyFile() else { return }
        guard Task.isCancelled == false, generation == self.generation, keyFile == nil,
              keyFileSelection.revision == revision, associationRevision == self.associationRevision,
              association == session.keyFileAssociation, session.state != .unlocked,
              declinesAssociation == false else {
            SecureWipe.wipe(&associated.data)
            return
        }
        knownAssociation = session.keyFileAssociation
        keyFile = KeyFile(name: associated.filename, data: associated.data, isAssociated: true)
    }

    /// Run when the reference may have changed: a cleared association wipes the
    /// loaded bytes and a new one is read, unless a file was picked here.
    func reconcileKeyFileAssociation() async {
        let current = session.keyFileAssociation
        guard current != knownAssociation else { return }
        knownAssociation = current
        associationRevision += 1
        declinesAssociation = false
        if keyFile?.isAssociated == true { wipeKeyFile() }
        await loadAssociatedKeyFileIfNeeded()
    }

    /// Applies the password rule when the window changes page.
    func windowDidShow(_ page: MacDatabaseOpenPage?) {
        if case .form = page { return }
        password = ""
        isPasswordVisible = false
    }

    func locateDatabaseFile() async {
        guard session.canRelinkDatabaseFile, let url = await filePicker.locateDatabase() else { return }
        guard DocumentPickerService.isSupportedDatabaseSelection(url) else {
            selectionAlert = DocumentPickerService.invalidDatabaseSelectionAlert()
            return
        }
        do {
            try session.relinkDatabaseFile(to: url)
        } catch {
            selectionAlert = DocumentPickerService.fileAccessFailureAlert(for: error)
        }
    }

    /// A recovery page's Try Again: back to the form, for the password or Touch ID.
    func tryAgain() {
        session.dismissOpenFailure()
    }

    /// A recovery page's Reconnect: signs in to the server again, then returns
    /// to the form, since no password was kept to retry the open with.
    func reconnect(authenticate: @MainActor () async throws -> Void) async {
        guard isReconnecting == false, case .error = session.state else { return }
        isReconnecting = true
        let generation = generation
        defer { if generation == self.generation { isReconnecting = false } }
        do {
            try await authenticate()
            guard generation == self.generation, case .error = session.state else { return }
            session.dismissOpenFailure()
        } catch let error as CloudProviderError where error == .authenticationCancelled {
            return
        } catch {
            guard generation == self.generation else { return }
            selectionAlert = DocumentPickerService.SelectionAlert(
                title: String(localized: "Reconnect Cloud Account"),
                message: error.localizedDescription
            )
        }
    }

    /// Whether Escape may close the window; never while an open is running.
    func escape() -> Bool {
        isUnlocking == false
    }

    /// Run on unlock and when the window closes.
    func clearSecrets() {
        generation += 1
        password = ""
        isPasswordVisible = false
        showsFieldError = false
        isReconnecting = false
        declinesAssociation = false
        keyFileSelection.cancel()
        wipeKeyFile()
    }

    private func wipeKeyFile() {
        guard var keyFile else { return }
        self.keyFile = nil
        SecureWipe.wipe(&keyFile.data)
    }

    private static func uiTestKeyFile() -> KeyFile? {
        #if DEBUG
        let processInfo = ProcessInfo.processInfo
        guard processInfo.arguments.contains("-ui-testing"),
              let base64 = processInfo.environment["UI_TEST_KEYFILE_BASE64"], base64.isEmpty == false,
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        return KeyFile(name: processInfo.environment["UI_TEST_KEYFILE_FILENAME"] ?? "test.key", data: data,
            isAssociated: false)
        #else
        return nil
        #endif
    }
}
#endif
