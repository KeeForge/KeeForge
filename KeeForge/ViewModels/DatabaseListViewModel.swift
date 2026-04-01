import Foundation

struct DatabaseRowStatus: Equatable, Sendable {
    var hasStoredKey: Bool
    var hasAccessIssue: Bool
}

@MainActor @Observable
final class DatabaseListViewModel {
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private(set) var databases: [DatabaseReference] = []
    private(set) var rowStatuses: [UUID: DatabaseRowStatus] = [:]
    private var didConsumeInitialLaunchSelection = false

    init() {
        reload()
    }

    func reload() {
        databases = DatabaseListStore.databases
        refreshRowStatuses()
    }

    func databaseToAutoOpenOnLaunch() -> DatabaseReference? {
        guard didConsumeInitialLaunchSelection == false else { return nil }
        didConsumeInitialLaunchSelection = true
        guard databases.count == 1 else { return nil }
        return databases.first
    }

    func addDatabase(from url: URL) throws -> DatabaseReference {
        let reference = try DatabaseListStore.add(url: url)
        reload()
        return reference
    }

    func removeDatabase(_ reference: DatabaseReference) {
        DatabaseListStore.remove(id: reference.id)
        reload()
    }

    func moveDatabases(from source: IndexSet, to destination: Int) {
        DatabaseListStore.move(from: source, to: destination)
        reload()
    }

    func toggleQuickLaunch(for reference: DatabaseReference) {
        update(reference) { updatedReference in
            updatedReference.isQuickLaunch.toggle()
        }
    }

    func setNickname(_ nickname: String?, for reference: DatabaseReference) {
        update(reference) { updatedReference in
            updatedReference.nickname = nickname
        }
    }

    func setKeyFile(url: URL?, for reference: DatabaseReference) throws {
        try update(reference) { updatedReference in
            if let url {
                updatedReference.keyFileBookmarkData = try url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                updatedReference.keyFileFilename = url.lastPathComponent
            } else {
                updatedReference.keyFileBookmarkData = nil
                updatedReference.keyFileFilename = nil
            }
        }
    }

    func refreshBookmarks() {
        DatabaseListStore.refreshBookmarks()
        reload()
    }

    func status(for reference: DatabaseReference) -> DatabaseRowStatus {
        rowStatuses[reference.id] ?? .init(hasStoredKey: false, hasAccessIssue: false)
    }

    func lastOpenedDescription(for reference: DatabaseReference) -> String? {
        guard let lastOpenedAt = reference.lastOpenedAt else { return nil }
        let relative = Self.relativeDateFormatter.localizedString(for: lastOpenedAt, relativeTo: .now)
        return "Last opened \(relative)"
    }

    func detailSubtitle(for reference: DatabaseReference) -> String? {
        if reference.showsFilenameSubtitle {
            return reference.filename
        }
        return nil
    }

    func biometricIndicatorSymbolName() -> String {
        switch BiometricService.availableType {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        case .none:
            return "key.fill"
        }
    }

    // MARK: - Private

    private func update(_ reference: DatabaseReference, mutate: (inout DatabaseReference) throws -> Void) rethrows {
        guard var updatedReference = databases.first(where: { $0.id == reference.id }) else { return }
        try mutate(&updatedReference)
        DatabaseListStore.update(updatedReference)
        reload()
    }

    private func refreshRowStatuses() {
        var updatedStatuses: [UUID: DatabaseRowStatus] = [:]

        for reference in databases {
            let resolvedURL = DatabaseListStore.resolveDatabaseURL(for: reference)
            let hasAccessIssue: Bool
            if let resolvedURL {
                hasAccessIssue = FileManager.default.fileExists(atPath: resolvedURL.path) == false
            } else {
                hasAccessIssue = true
            }

            updatedStatuses[reference.id] = DatabaseRowStatus(
                hasStoredKey: KeychainService.hasStoredKey(
                    for: reference.id,
                    legacyFilename: reference.legacyKeychainFilename
                ),
                hasAccessIssue: hasAccessIssue
            )
        }

        rowStatuses = updatedStatuses
        databases = DatabaseListStore.databases
    }
}
