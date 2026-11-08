import Foundation

enum DatabaseCreationDestinationChoice: String, CaseIterable, Identifiable {
    case files
    case dropbox
    case oneDrive
    case googleDrive
    case webDAV
    case ftp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files:
            String(localized: "Local Files")
        case .dropbox:
            "Dropbox"
        case .oneDrive:
            "OneDrive"
        case .googleDrive:
            "Google Drive"
        case .webDAV:
            "WebDAV"
        case .ftp:
            "FTP"
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
        case .googleDrive:
            .googleDrive
        case .webDAV:
            .webDAV
        case .ftp:
            .ftp
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

struct CloudCreationRecoveryItem: Identifiable, Sendable {
    let id: UUID
    let filename: String
    let destination: String
    let isPaused: Bool
    let issue: String?
}

@MainActor @Observable
final class DatabaseCreationViewModel {
    typealias PreparationOperation = @Sendable (
        DatabasePreparationRequest, DatabaseCreationService.Environment
    ) async throws -> PreparedDatabase

    typealias CloudCreationOperation = @Sendable (
        PreparedDatabase, DatabaseCreationDestination, DatabaseCreationService.Environment
    ) async throws -> CreatedDatabase

    struct RecoveryOperations: Sendable {
        var list: @Sendable () async throws -> [CloudCreationRecoveryItem]
        var resume: @Sendable (UUID) async throws -> DatabaseReference
        var cancel: @Sendable (UUID) async throws -> Void

        static let live = RecoveryOperations(
            list: {
                try await Task.detached(priority: .utility) {
                    try PendingUploadQueue.listCreations().filter { !$0.isConflictCopy }.map {
                        CloudCreationRecoveryItem(id: $0.operationID, filename: $0.referenceTemplate.filename,
                            destination: $0.target.path, isPaused: $0.isPaused, issue: $0.lastIssue?.localizedDescription)
                    }
                }.value
            },
            resume: { id in try await CloudFileCreationCoordinator.resume(operationID: id) },
            cancel: { id in
                try await Task.detached(priority: .utility) { try CloudFileCreationCoordinator.cancel(operationID: id) }.value
            }
        )
    }

    private let recoveryOperations: RecoveryOperations
    private var recoveryGeneration = UUID()
    private var recoveryListGeneration = UUID()
    private(set) var pendingCreations: [CloudCreationRecoveryItem] = []
    private(set) var isRecovering = false
    private(set) var recoveryMessage: String?
    private let cloudCreationOperation: CloudCreationOperation
    private var formRevision: UInt64 = 0
    private var isClearingSecrets = false
    private var preparedDestination: DatabaseCreationDestination?
    private let environment: DatabaseCreationService.Environment
    private let preparationOperation: PreparationOperation
    private var isCancelled = false

    init(
        environment: DatabaseCreationService.Environment = .live,
        recoveryOperations: RecoveryOperations = .live,
        preparationOperation: @escaping PreparationOperation = { request, environment in
            try await DatabaseCreationService.prepare(request: request, environment: environment)
        },
        cloudCreationOperation: @escaping CloudCreationOperation = { prepared, destination, environment in
            try await DatabaseCreationService.create(prepared: prepared, destination: destination, environment: environment)
        }
    ) {
        self.recoveryOperations = recoveryOperations
        self.cloudCreationOperation = cloudCreationOperation
        self.environment = environment
        self.preparationOperation = preparationOperation
    }

    var databaseName = "" {
        didSet { if databaseName != oldValue { invalidatePreparedForm() } }
    }
    var password = "" {
        didSet { if password != oldValue { invalidatePreparedForm() } }
    }
    var confirmPassword = "" {
        didSet { if confirmPassword != oldValue { invalidatePreparedForm() } }
    }
    var destinationChoice: DatabaseCreationDestinationChoice = .files {
        didSet { if destinationChoice != oldValue { invalidatePreparedForm() } }
    }
    var cipher: DatabaseCreationCipher = .aes256 {
        didSet { if cipher != oldValue { invalidatePreparedForm() } }
    }
    var kdfPreset: DatabaseCreationKDFPreset = .balanced {
        didSet { if kdfPreset != oldValue { invalidatePreparedForm() } }
    }
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

    var filenamePreview: String? {
        try? DatabaseCreationService.normalizedFilename(for: databaseName)
    }

    var showsFilenameReplacementExplanation: Bool {
        filenamePreview != nil
            && databaseName.rangeOfCharacter(from: DatabaseCreationService.filenameReplacementCharacters) != nil
    }

    var suggestedFilename: String {
        filenamePreview ?? "New Database.kdbx"
    }

    var preparedFilename: String {
        preparedDatabase?.filename ?? suggestedFilename
    }

    var preparedEncryptedBytes: Data {
        preparedDatabase?.encryptedBytes ?? Data()
    }

    func selectKeyFile(url: URL) throws {
        invalidatePreparedForm()
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        keyFileData = try Data(contentsOf: url)
        keyFileBookmarkData = try SecurityScopedBookmarkManager.makeBookmarkData(for: url, readOnly: true)
        keyFileFilename = url.lastPathComponent
        clearDisplayedErrors()
    }

    func clearKeyFile() {
        invalidatePreparedForm()
        keyFileData = nil
        keyFileBookmarkData = nil
        keyFileFilename = nil
        clearDisplayedErrors()
    }

    func prepareForExport() async -> Bool {
        guard isCreating == false, isRecovering == false, isCancelled == false else { return false }
        guard validate() else { return false }

        let revision = formRevision
        isCreating = true
        creationError = nil
        defer {
            isCreating = false
        }

        do {
            let prepared = try await preparationOperation(
                DatabasePreparationRequest(
                    displayName: databaseName,
                    password: password.isEmpty ? nil : password,
                    keyFileData: keyFileData,
                    keyFileBookmarkData: keyFileBookmarkData,
                    keyFileFilename: keyFileFilename,
                    cipher: cipher,
                    kdfPreset: kdfPreset
                ),
                environment
            )
            guard isCancelled == false, Task.isCancelled == false, formRevision == revision else { return false }
            preparedDatabase = prepared
            clearSecrets()
            return true
        } catch {
            guard isCancelled == false, Task.isCancelled == false, formRevision == revision else { return false }
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
            exportedURL: url,
            environment: environment
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
        guard isCreating == false, isRecovering == false, isCancelled == false else { return nil }
        guard validate() else { return nil }

        let revision = formRevision
        isCreating = true
        creationError = nil
        defer {
            isCreating = false
        }

        do {
            let destination = DatabaseCreationDestination.cloud(provider: provider, accountId: accountID, folderPath: folderPath)
            let prepared: PreparedDatabase
            if let existing = preparedDatabase, preparedDestination == destination {
                prepared = existing
            } else {
                prepared = try await preparationOperation(
                    DatabasePreparationRequest(
                        displayName: databaseName,
                        password: password.isEmpty ? nil : password,
                        keyFileData: keyFileData,
                        keyFileBookmarkData: keyFileBookmarkData,
                        keyFileFilename: keyFileFilename,
                        cipher: cipher,
                        kdfPreset: kdfPreset
                    ),
                    environment
                )
                guard isCancelled == false, Task.isCancelled == false, formRevision == revision else { return nil }
                preparedDatabase = prepared
                preparedDestination = destination
            }
            let created = try await cloudCreationOperation(prepared, destination, environment)
            guard isCancelled == false, Task.isCancelled == false, formRevision == revision else { return nil }
            clearSecrets()
            preparedDatabase = nil
            return created
        } catch {
            guard isCancelled == false, Task.isCancelled == false, formRevision == revision else { return nil }
            creationError = cloudCreationMessage(for: error)
            await refreshPendingCreations()
            return nil
        }
    }

    func refreshPendingCreations() async {
        guard !isCancelled else { return }
        let generation = UUID()
        recoveryListGeneration = generation
        do {
            let items = try await recoveryOperations.list()
            guard !isCancelled, !Task.isCancelled, recoveryListGeneration == generation else { return }
            pendingCreations = items
        } catch {
            guard !isCancelled, !Task.isCancelled, recoveryListGeneration == generation else { return }
            recoveryMessage = error.localizedDescription
        }
    }

    func resumeCreation(_ item: CloudCreationRecoveryItem) async -> DatabaseReference? {
        guard !isCancelled, !isCreating, !isRecovering, pendingCreations.contains(where: { $0.id == item.id }) else { return nil }
        isRecovering = true
        recoveryMessage = nil
        let generation = UUID()
        recoveryGeneration = generation
        defer { isRecovering = false }
        do {
            let reference = try await recoveryOperations.resume(item.id)
            guard !isCancelled, !Task.isCancelled, recoveryGeneration == generation else { return nil }
            recoveryListGeneration = UUID()
            clearSecrets()
            clearPreparedDatabase()
            pendingCreations.removeAll { $0.id == item.id }
            return reference
        } catch {
            guard !isCancelled, !Task.isCancelled, recoveryGeneration == generation else { return nil }
            recoveryMessage = error.localizedDescription
            await refreshPendingCreations()
            return nil
        }
    }

    func cancelCreation(_ item: CloudCreationRecoveryItem) async {
        guard !isCancelled, !isCreating, !isRecovering, pendingCreations.contains(where: { $0.id == item.id }) else { return }
        isRecovering = true
        defer { isRecovering = false }
        do {
            try await recoveryOperations.cancel(item.id)
            guard !isCancelled, !Task.isCancelled else { return }
            if preparedDatabase?.id == item.id { clearPreparedDatabase() }
            await refreshPendingCreations()
        } catch {
            guard !isCancelled, !Task.isCancelled else { return }
            recoveryMessage = error.localizedDescription
        }
    }

    func clearSecrets() {
        isClearingSecrets = true
        defer { isClearingSecrets = false }
        password = ""
        confirmPassword = ""
        keyFileData = nil
    }

    func clearPreparedDatabase() {
        preparedDatabase = nil
        preparedDestination = nil
    }

    private func invalidatePreparedForm() {
        guard !isClearingSecrets else { return }
        formRevision &+= 1
        clearPreparedDatabase()
    }

    func cancelPendingCreation() {
        isCancelled = true
        recoveryGeneration = UUID()
        recoveryListGeneration = UUID()
        clearSecrets()
        clearPreparedDatabase()
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
