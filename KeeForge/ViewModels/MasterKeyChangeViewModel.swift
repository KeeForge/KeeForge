import Foundation

/// Form state for the Change Master Key screen (`../Views/MasterKeyChangeView.swift`).
/// The rekey itself lives in `DatabaseViewModel.changeMasterKey`; the view injects
/// it (and the current-key-file loader) as closures so this model stays testable
/// without an unlocked session.
@MainActor @Observable
final class MasterKeyChangeViewModel {
    enum KeyFileChange: Equatable {
        case keepCurrent
        case replace
        case remove
    }

    typealias ChangeOperation = @MainActor (
        _ newPassword: String?,
        _ newKeyFileData: Data?,
        _ newKeyFileBookmarkData: Data?,
        _ newKeyFileFilename: String?
    ) async throws -> Void
    typealias CurrentKeyFileLoader = @MainActor () async -> (data: Data, filename: String)?

    var newPassword = ""
    var confirmPassword = ""
    var validationError: String?
    var changeError: String?
    private(set) var isWorking = false
    private(set) var keyFileChange: KeyFileChange = .keepCurrent
    private(set) var pickedKeyFileData: Data?
    private(set) var pickedKeyFileBookmarkData: Data?
    private(set) var pickedKeyFileFilename: String?

    private let currentKeyFileFilename: String?
    private let currentKeyFileBookmarkData: Data?
    private let loadCurrentKeyFile: CurrentKeyFileLoader
    private let changeOperation: ChangeOperation

    init(
        currentKeyFileFilename: String?,
        currentKeyFileBookmarkData: Data?,
        loadCurrentKeyFile: @escaping CurrentKeyFileLoader,
        changeOperation: @escaping ChangeOperation
    ) {
        self.currentKeyFileFilename = currentKeyFileFilename
        self.currentKeyFileBookmarkData = currentKeyFileBookmarkData
        self.loadCurrentKeyFile = loadCurrentKeyFile
        self.changeOperation = changeOperation
    }

    var passwordStrengthWarning: String? {
        guard let estimate = PasswordStrengthEstimator.estimate(newPassword) else { return nil }
        switch estimate.level {
        case .veryWeak, .weak:
            return String(localized: "This password is weak. You can still change the master key, but a longer unique password is safer.")
        case .good, .veryGood:
            return nil
        }
    }

    var keyFileSummary: String {
        switch keyFileChange {
        case .keepCurrent:
            currentKeyFileFilename ?? String(localized: "None")
        case .replace:
            pickedKeyFileFilename ?? String(localized: "None")
        case .remove:
            String(localized: "None")
        }
    }

    var hasEffectiveKeyFile: Bool {
        switch keyFileChange {
        case .keepCurrent:
            hasCurrentKeyFile
        case .replace:
            pickedKeyFileData != nil
        case .remove:
            false
        }
    }

    private var hasCurrentKeyFile: Bool {
        currentKeyFileBookmarkData != nil || currentKeyFileFilename != nil
    }

    func selectKeyFile(url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        pickedKeyFileData = try Data(contentsOf: url)
        pickedKeyFileBookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: url)
        pickedKeyFileFilename = url.lastPathComponent
        keyFileChange = .replace
        clearDisplayedErrors()
    }

    func clearKeyFile() {
        pickedKeyFileData = nil
        pickedKeyFileBookmarkData = nil
        pickedKeyFileFilename = nil
        keyFileChange = hasCurrentKeyFile ? .remove : .keepCurrent
        clearDisplayedErrors()
    }

    func clearSecrets() {
        newPassword = ""
        confirmPassword = ""
        pickedKeyFileData = nil
    }

    func validate() -> Bool {
        clearDisplayedErrors()

        guard newPassword == confirmPassword else {
            validationError = String(localized: "Password confirmation does not match.")
            return false
        }

        guard newPassword.isEmpty == false || hasEffectiveKeyFile else {
            validationError = DatabaseCreationService.CreationError.missingKeyComponent.localizedDescription
            return false
        }

        return true
    }

    func performChange() async -> Bool {
        guard isWorking == false else { return false }
        guard validate() else { return false }

        isWorking = true
        defer {
            isWorking = false
        }

        let effectiveKeyFile: (data: Data?, bookmark: Data?, filename: String?)
        switch keyFileChange {
        case .keepCurrent:
            if hasCurrentKeyFile {
                guard let current = await loadCurrentKeyFile() else {
                    changeError = String(localized: "The current key file could not be read. Select it again or clear it, then try again.")
                    return false
                }
                effectiveKeyFile = (current.data, currentKeyFileBookmarkData, currentKeyFileFilename ?? current.filename)
            } else {
                effectiveKeyFile = (nil, nil, nil)
            }
        case .replace:
            effectiveKeyFile = (pickedKeyFileData, pickedKeyFileBookmarkData, pickedKeyFileFilename)
        case .remove:
            effectiveKeyFile = (nil, nil, nil)
        }

        do {
            try await changeOperation(
                newPassword.isEmpty ? nil : newPassword,
                effectiveKeyFile.data,
                effectiveKeyFile.bookmark,
                effectiveKeyFile.filename
            )
            clearSecrets()
            return true
        } catch {
            changeError = Self.message(for: error)
            return false
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case DatabaseViewModel.RekeyError.sessionUnavailable:
            String(localized: "The database is locked. Unlock it and try again.")
        case DatabaseViewModel.RekeyError.databaseIsReadOnly:
            SaveError.databaseIsReadOnly.localizedDescription
        case DatabaseViewModel.RekeyError.saveInProgress:
            String(localized: "Another save is in progress. Wait for it to finish, then try again.")
        case DatabaseViewModel.RekeyError.unsavedChanges:
            String(localized: "Save or discard your changes before changing the master key.")
        case DatabaseViewModel.RekeyError.missingKeyComponent:
            DatabaseCreationService.CreationError.missingKeyComponent.localizedDescription
        case DatabaseViewModel.RekeyError.pendingUploadsExist:
            String(localized: "This database has pending AutoFill changes. Let them finish syncing, then try again.")
        case DatabaseViewModel.RekeyError.conflict:
            String(localized: "The database file changed since it was opened. Reload the database and try again.")
        default:
            error.localizedDescription
        }
    }

    private func clearDisplayedErrors() {
        validationError = nil
        changeError = nil
    }
}
