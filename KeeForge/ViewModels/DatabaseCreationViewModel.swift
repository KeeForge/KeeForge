import Foundation

enum DatabaseCreationDestinationChoice: String, CaseIterable, Identifiable {
    case files
    case dropbox
    case oneDrive
    case webDAV

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files:
            String(localized: "Local Files")
        case .dropbox:
            "Dropbox"
        case .oneDrive:
            "OneDrive"
        case .webDAV:
            "WebDAV"
        }
    }

    var cloudProviderKind: CloudProviderKind? {
        switch self {
        case .files:
            nil
        case .dropbox:
            .dropbox
        case .oneDrive:
            .oneDrive
        case .webDAV:
            .webDAV
        }
    }

    /// Destination choices shown in the New Database picker, filtered by the
    /// same per-platform cloud availability gate used by the add/import menus.
    /// Local Files always stays; a cloud choice appears only when its provider
    /// is available on the current platform.
    static var availableChoices: [DatabaseCreationDestinationChoice] {
        allCases.filter { choice in
            guard let providerKind = choice.cloudProviderKind else { return true }
            return providerKind.isAvailableOnCurrentPlatform
        }
    }
}

@MainActor @Observable
final class DatabaseCreationViewModel {
    var databaseName = ""
    var password = ""
    var confirmPassword = ""
    var destinationChoice: DatabaseCreationDestinationChoice = .files
    private(set) var keyFileData: Data?
    private(set) var keyFileBookmarkData: Data?
    private(set) var keyFileFilename: String?
    private(set) var preparedDatabase: PreparedDatabase?
    private(set) var isCreating = false
    var validationError: String?
    var creationError: String?

    var keyFileSummary: String {
        keyFileFilename ?? String(localized: "None")
    }

    var passwordStrengthWarning: String? {
        guard let estimate = PasswordStrengthEstimator.estimate(password) else { return nil }
        switch estimate.level {
        case .veryWeak, .weak:
            return String(localized: "This password is weak. You can still create the database, but a longer unique password is safer.")
        case .good, .veryGood:
            return nil
        }
    }

    var suggestedFilename: String {
        (try? DatabaseCreationService.normalizedFilename(for: databaseName)) ?? "New Database.kdbx"
    }

    var preparedFilename: String {
        preparedDatabase?.filename ?? suggestedFilename
    }

    var preparedEncryptedBytes: Data {
        preparedDatabase?.encryptedBytes ?? Data()
    }

    func selectKeyFile(url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        keyFileData = try Data(contentsOf: url)
        keyFileBookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: url)
        keyFileFilename = url.lastPathComponent
        clearDisplayedErrors()
    }

    func clearKeyFile() {
        keyFileData = nil
        keyFileBookmarkData = nil
        keyFileFilename = nil
        clearDisplayedErrors()
    }

    func prepareForExport() async -> Bool {
        guard isCreating == false else { return false }
        guard validate() else { return false }

        isCreating = true
        creationError = nil
        defer {
            isCreating = false
        }

        do {
            preparedDatabase = try await DatabaseCreationService.prepare(
                request: DatabasePreparationRequest(
                    displayName: databaseName,
                    password: password.isEmpty ? nil : password,
                    keyFileData: keyFileData,
                    keyFileBookmarkData: keyFileBookmarkData,
                    keyFileFilename: keyFileFilename
                )
            )
            clearSecrets()
            return true
        } catch {
            creationError = error.localizedDescription
            return false
        }
    }

    func completeExport(to url: URL) throws -> CreatedDatabase {
        guard let preparedDatabase else {
            throw DatabaseCreationService.CreationError.destinationUnavailable
        }

        let created = try DatabaseCreationService.registerExported(
            preparedDatabase,
            exportedURL: url
        )
        self.preparedDatabase = nil
        return created
    }

    func validateForDestinationSelection() -> Bool {
        validate()
    }

    func createInCloud(
        provider: String,
        accountID: String,
        folderPath: String?
    ) async -> CreatedDatabase? {
        guard isCreating == false else { return nil }
        guard validate() else { return nil }

        isCreating = true
        creationError = nil
        defer {
            isCreating = false
        }

        do {
            let created = try await DatabaseCreationService.create(
                request: DatabaseCreationRequest(
                    displayName: databaseName,
                    destination: .cloud(
                        provider: provider,
                        accountId: accountID,
                        folderPath: folderPath
                    ),
                    password: password.isEmpty ? nil : password,
                    keyFileData: keyFileData,
                    keyFileBookmarkData: keyFileBookmarkData,
                    keyFileFilename: keyFileFilename
                )
            )
            clearSecrets()
            preparedDatabase = nil
            return created
        } catch {
            creationError = cloudCreationMessage(for: error)
            return nil
        }
    }

    func clearSecrets() {
        password = ""
        confirmPassword = ""
        keyFileData = nil
    }

    func clearPreparedDatabase() {
        preparedDatabase = nil
    }

    private func validate() -> Bool {
        clearDisplayedErrors()

        do {
            _ = try DatabaseCreationService.normalizedFilename(for: databaseName)
        } catch {
            validationError = error.localizedDescription
            return false
        }

        guard password == confirmPassword else {
            validationError = String(localized: "Password confirmation does not match.")
            return false
        }

        guard password.isEmpty == false || keyFileData != nil else {
            validationError = DatabaseCreationService.CreationError.missingKeyComponent.localizedDescription
            return false
        }

        return true
    }

    private func cloudCreationMessage(for error: Error) -> String {
        if case CloudProviderError.conflict = error {
            return String(localized: "A database with this name already exists in this cloud folder.")
        }

        return error.localizedDescription
    }

    private func clearDisplayedErrors() {
        validationError = nil
        creationError = nil
    }
}
