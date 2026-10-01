import Foundation

/// A key derivation the Encryption Settings screen writes. Wider than
/// creation's Argon2id presets: an existing database may also move to AES-KDF,
/// which new databases never get.
enum EncryptionSettingsKeyDerivation: Hashable, Sendable {
    case argon2id(DatabaseCreationKDFPreset)
    case aesKDF(rounds: UInt64)

    func kdfParameters() throws -> [String: Any] {
        switch self {
        case .argon2id(let preset):
            try DatabaseCreationDefaults.argon2idKDFParameters(preset: preset)
        case .aesKDF(let rounds):
            try DatabaseCreationDefaults.aesKDFParameters(rounds: rounds)
        }
    }
}

/// Form state for the Encryption Settings screen (`../Views/DatabaseList/EncryptionSettingsView.swift`).
/// The re-encryption itself lives in `DatabaseViewModel.changeEncryptionSettings`;
/// the view injects it as a closure so this model stays testable without an
/// unlocked session.
///
/// Offers the same choices as database creation plus AES-KDF with editable
/// rounds. A file whose cipher or key derivation is outside that set keeps it
/// as a `nil` selection, which is never written unless the user picks one of
/// the offered values.
@MainActor @Observable
final class EncryptionSettingsViewModel {
    typealias ChangeOperation = @MainActor (
        _ cipher: DatabaseCreationCipher?,
        _ keyDerivation: EncryptionSettingsKeyDerivation?,
        _ isCompressed: Bool?
    ) async throws -> Void

    enum KeyDerivationOption: Hashable, Identifiable {
        case argon2id(DatabaseCreationKDFPreset)
        case aesKDF

        static let allCases: [KeyDerivationOption] =
            DatabaseCreationKDFPreset.allCases.map { .argon2id($0) } + [.aesKDF]

        var id: Self { self }

        var displayName: String {
            switch self {
            case .argon2id(let preset): preset.displayName
            case .aesKDF: "AES-KDF"
            }
        }
    }

    var cipher: DatabaseCreationCipher? {
        didSet { if cipher != oldValue { changeError = nil } }
    }
    var keyDerivation: KeyDerivationOption? {
        didSet { if keyDerivation != oldValue { changeError = nil } }
    }
    /// Only read while `keyDerivation` is `.aesKDF`.
    var aesKDFRoundsText: String {
        didSet { if aesKDFRoundsText != oldValue { changeError = nil } }
    }
    var isCompressed: Bool {
        didSet { if isCompressed != oldValue { changeError = nil } }
    }
    var changeError: String?
    private(set) var isWorking = false

    let current: KDBXFileSummary
    private let initialCipher: DatabaseCreationCipher?
    private let initialKeyDerivation: EncryptionSettingsKeyDerivation?
    private let changeOperation: ChangeOperation

    init(current: KDBXFileSummary, changeOperation: @escaping ChangeOperation) {
        self.current = current
        self.changeOperation = changeOperation
        initialCipher = Self.cipher(matching: current.cipher)
        initialKeyDerivation = Self.keyDerivation(matching: current.keyDerivation)
        cipher = initialCipher
        switch initialKeyDerivation {
        case .argon2id(let preset):
            keyDerivation = .argon2id(preset)
            aesKDFRoundsText = String(DatabaseCreationDefaults.aesKDFRounds)
        case .aesKDF(let rounds):
            keyDerivation = .aesKDF
            aesKDFRoundsText = String(rounds)
        case nil:
            keyDerivation = nil
            aesKDFRoundsText = String(DatabaseCreationDefaults.aesKDFRounds)
        }
        isCompressed = current.isCompressed
    }

    /// True when the file's cipher is not one creation offers, so the picker
    /// needs a "current" option to show it.
    var showsCurrentCipherOption: Bool {
        initialCipher == nil
    }

    var showsCurrentKDFOption: Bool {
        initialKeyDerivation == nil
    }

    var showsAESKDFRounds: Bool {
        keyDerivation == .aesKDF
    }

    /// Rounds the parser accepts, so a changed file always reopens.
    var aesKDFRounds: UInt64? {
        guard let rounds = UInt64(aesKDFRoundsText.trimmingCharacters(in: .whitespaces)),
              (1...KDBXParser.aesKDFMaxRounds).contains(rounds) else {
            return nil
        }
        return rounds
    }

    var aesKDFRoundsError: String? {
        guard showsAESKDFRounds, aesKDFRounds == nil else { return nil }
        return String(localized: "Enter a number of rounds from 1 to \(KDBXParser.aesKDFMaxRounds.formatted()).")
    }

    var currentCipherOptionTitle: String {
        String(localized: "\(current.cipherDisplayName) (Current)")
    }

    var currentKDFOptionTitle: String {
        String(localized: "\(current.keyDerivationDisplayName) (Current)")
    }

    var keyDerivationSummary: String {
        switch keyDerivation {
        case .argon2id(let preset):
            return String(localized: "Argon2id key derivation (\(preset.parameterSummary)).")
        case .aesKDF:
            let name = KeyDerivationOption.aesKDF.displayName
            guard let aesKDFRounds else { return name }
            let detail = String(localized: "\(aesKDFRounds.formatted()) rounds")
            return String(localized: "\(name) key derivation (\(detail)).")
        case nil:
            break
        }
        guard let detail = current.keyDerivationDetailText else {
            return current.keyDerivationDisplayName
        }
        return String(localized: "\(current.keyDerivationDisplayName) key derivation (\(detail)).")
    }

    /// The selection as it would be written; `nil` while AES-KDF rounds are
    /// invalid, which `canSave` refuses.
    private var selectedKeyDerivation: EncryptionSettingsKeyDerivation? {
        switch keyDerivation {
        case .argon2id(let preset): .argon2id(preset)
        case .aesKDF: aesKDFRounds.map { .aesKDF(rounds: $0) }
        case nil: nil
        }
    }

    var hasChanges: Bool {
        cipher != initialCipher
            || selectedKeyDerivation != initialKeyDerivation
            || aesKDFRoundsError != nil
            || isCompressed != current.isCompressed
    }

    var canSave: Bool {
        hasChanges && aesKDFRoundsError == nil
    }

    func performChange() async -> Bool {
        guard isWorking == false, canSave else { return false }

        isWorking = true
        defer {
            isWorking = false
        }
        changeError = nil

        do {
            try await changeOperation(
                cipher != initialCipher ? cipher : nil,
                selectedKeyDerivation != initialKeyDerivation ? selectedKeyDerivation : nil,
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

    /// An Argon2id preset matches on the two values it sets; parallelism is
    /// device-derived at creation, so a preset written on another device still
    /// counts.
    private static func keyDerivation(
        matching keyDerivation: KDBXFileSummary.KeyDerivation
    ) -> EncryptionSettingsKeyDerivation? {
        switch keyDerivation {
        case .aesKDF(let rounds):
            return .aesKDF(rounds: rounds)
        case .argon2id(let iterations, let memoryBytes, _):
            return DatabaseCreationKDFPreset.allCases
                .first { $0.iterations == iterations && $0.memoryBytes == memoryBytes }
                .map { .argon2id($0) }
        case .argon2d, .unknown:
            return nil
        }
    }
}
