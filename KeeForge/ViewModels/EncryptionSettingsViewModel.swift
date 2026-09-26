import Foundation

/// Form state for the Encryption Settings screen (`../Views/DatabaseList/EncryptionSettingsView.swift`).
/// The re-encryption itself lives in `DatabaseViewModel.changeEncryptionSettings`;
/// the view injects it as a closure so this model stays testable without an
/// unlocked session.
///
/// Offers the same choices as database creation. A file whose cipher or key
/// derivation is outside that set keeps it as a `nil` selection, which is
/// never written unless the user picks one of the offered values.
@MainActor @Observable
final class EncryptionSettingsViewModel {
    typealias ChangeOperation = @MainActor (
        _ cipher: DatabaseCreationCipher?,
        _ kdfPreset: DatabaseCreationKDFPreset?,
        _ isCompressed: Bool?
    ) async throws -> Void

    var cipher: DatabaseCreationCipher? {
        didSet { if cipher != oldValue { changeError = nil } }
    }
    var kdfPreset: DatabaseCreationKDFPreset? {
        didSet { if kdfPreset != oldValue { changeError = nil } }
    }
    var isCompressed: Bool {
        didSet { if isCompressed != oldValue { changeError = nil } }
    }
    var changeError: String?
    private(set) var isWorking = false

    let current: KDBXFileSummary
    private let initialCipher: DatabaseCreationCipher?
    private let initialKDFPreset: DatabaseCreationKDFPreset?
    private let changeOperation: ChangeOperation

    init(current: KDBXFileSummary, changeOperation: @escaping ChangeOperation) {
        self.current = current
        self.changeOperation = changeOperation
        initialCipher = Self.cipher(matching: current.cipher)
        initialKDFPreset = Self.kdfPreset(matching: current.keyDerivation)
        cipher = initialCipher
        kdfPreset = initialKDFPreset
        isCompressed = current.isCompressed
    }

    /// True when the file's cipher is not one creation offers, so the picker
    /// needs a "current" option to show it.
    var showsCurrentCipherOption: Bool {
        initialCipher == nil
    }

    var showsCurrentKDFOption: Bool {
        initialKDFPreset == nil
    }

    var currentCipherOptionTitle: String {
        String(localized: "\(current.cipherDisplayName) (Current)")
    }

    var currentKDFOptionTitle: String {
        String(localized: "\(current.keyDerivationDisplayName) (Current)")
    }

    var keyDerivationSummary: String {
        if let kdfPreset {
            return String(localized: "Argon2id key derivation (\(kdfPreset.parameterSummary)).")
        }
        guard let detail = current.keyDerivationDetailText else {
            return current.keyDerivationDisplayName
        }
        return String(localized: "\(current.keyDerivationDisplayName) key derivation (\(detail)).")
    }

    var hasChanges: Bool {
        cipher != initialCipher || kdfPreset != initialKDFPreset || isCompressed != current.isCompressed
    }

    func performChange() async -> Bool {
        guard isWorking == false, hasChanges else { return false }

        isWorking = true
        defer {
            isWorking = false
        }
        changeError = nil

        do {
            try await changeOperation(
                cipher != initialCipher ? cipher : nil,
                kdfPreset != initialKDFPreset ? kdfPreset : nil,
                isCompressed != current.isCompressed ? isCompressed : nil
            )
            return true
        } catch {
            changeError = Self.message(for: error)
            return false
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case DatabaseViewModel.EncryptionSettingsError.sessionUnavailable:
            String(localized: "The database is locked. Unlock it and try again.")
        case DatabaseViewModel.EncryptionSettingsError.databaseIsReadOnly:
            SaveError.databaseIsReadOnly.localizedDescription
        case DatabaseViewModel.EncryptionSettingsError.saveInProgress:
            String(localized: "Another save is in progress. Wait for it to finish, then try again.")
        case DatabaseViewModel.EncryptionSettingsError.unsavedChanges:
            String(localized: "Save or discard your changes before changing encryption settings.")
        case DatabaseViewModel.EncryptionSettingsError.pendingUploadsExist:
            String(localized: "This database has pending AutoFill changes. Let them finish syncing, then try again.")
        case DatabaseViewModel.EncryptionSettingsError.conflict:
            String(localized: "The database file changed since it was opened. Reload the database and try again.")
        default:
            error.localizedDescription
        }
    }

    private static func cipher(matching cipher: KDBXOuterCipher?) -> DatabaseCreationCipher? {
        DatabaseCreationCipher.allCases.first { $0.cipherID == cipher?.uuid }
    }

    /// Matches on the two values a preset sets; parallelism is device-derived
    /// at creation, so a preset written on another device still counts.
    private static func kdfPreset(
        matching keyDerivation: KDBXFileSummary.KeyDerivation
    ) -> DatabaseCreationKDFPreset? {
        guard case .argon2id(let iterations, let memoryBytes, _) = keyDerivation else { return nil }
        return DatabaseCreationKDFPreset.allCases.first {
            $0.iterations == iterations && $0.memoryBytes == memoryBytes
        }
    }
}
