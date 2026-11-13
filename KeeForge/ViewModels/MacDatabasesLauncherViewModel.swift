#if os(macOS)
import Foundation
import Observation

/// What the Databases window offers. It lists and manages references and asks
/// the app to open or front a database's window; it never holds a session.
@MainActor @Observable
final class MacDatabasesLauncherViewModel {
    enum OpenAction: Equatable {
        case open
        case front
    }

    enum EmptyState: Equatable {
        /// Nothing has been added yet.
        case firstRun
        /// Every saved database uses a provider this Mac cannot reach.
        case noneAvailable
    }

    var selectedDatabaseID: UUID?
    var whatsNewRelease: WhatsNewRelease?
    var isChoosingEnrollmentDestination = false
    private(set) var connectRequest: ConnectRequest?

    struct ConnectRequest: Equatable {
        let id: Int
        let provider: CloudProviderKind
    }

    @ObservationIgnored private let references: @MainActor () -> [DatabaseReference]
    @ObservationIgnored var hasWindow: @MainActor (UUID) -> Bool = { _ in false }
    @ObservationIgnored var openDatabase: @MainActor (DatabaseReference) -> Void = { _ in }
    @ObservationIgnored var openCreatedDatabase: @MainActor (CreatedDatabase) -> Void = { _ in }
    @ObservationIgnored var chooseEnrollmentDestinationHandler: @MainActor (UUID) -> Void = { _ in }
    @ObservationIgnored var cancelEnrollmentDestinationHandler: @MainActor () -> Void = {}

    init(references: @escaping @MainActor () -> [DatabaseReference]) {
        self.references = references
    }

    static func isAvailable(_ reference: DatabaseReference) -> Bool {
        switch reference.source {
        case .local: true
        case .cloud(let metadata): metadata.providerKind.map(isServerProvider) == true
        }
    }

    /// Dropbox and OneDrive are never Mac destinations, even if a build were to report them available.
    static func isServerProvider(_ provider: CloudProviderKind) -> Bool {
        (provider == .webDAV || provider == .ftp) && provider.isAvailableOnCurrentPlatform
    }

    var databases: [DatabaseReference] { references().filter(Self.isAvailable) }

    var connectProviders: [CloudProviderKind] {
        CloudProviderRegistry.availableProviders.filter(Self.isServerProvider)
    }

    var emptyState: EmptyState? {
        let all = references()
        if all.isEmpty { return .firstRun }
        return all.contains(where: Self.isAvailable) ? nil : .noneAvailable
    }

    func openAction(for reference: DatabaseReference) -> OpenAction? {
        guard Self.isAvailable(reference) else { return nil }
        return hasWindow(reference.id) ? .front : .open
    }

    var selectedDatabase: DatabaseReference? {
        databases.first { $0.id == selectedDatabaseID }
    }

    var canOpenSelection: Bool { selectedDatabase != nil }

    func open(_ reference: DatabaseReference) {
        guard let current = databases.first(where: { $0.id == reference.id }), openAction(for: current) != nil else { return }
        selectedDatabaseID = current.id
        openDatabase(current)
    }

    func open(ids: Set<UUID>) {
        for reference in databases where ids.contains(reference.id) {
            open(reference)
        }
    }

    func openSelection() {
        guard let selectedDatabase else { return }
        open(selectedDatabase)
    }

    func didCreate(_ database: CreatedDatabase) {
        openCreatedDatabase(database)
    }

    func requestConnect(_ provider: CloudProviderKind) {
        guard connectProviders.contains(provider) else { return }
        connectRequest = ConnectRequest(id: (connectRequest?.id ?? 0) + 1, provider: provider)
    }

    var enrollmentCandidates: [DatabaseReference] { databases }

    func chooseEnrollmentDestination(_ databaseID: UUID) {
        guard isChoosingEnrollmentDestination, databases.contains(where: { $0.id == databaseID }) else { return }
        isChoosingEnrollmentDestination = false
        chooseEnrollmentDestinationHandler(databaseID)
    }

    func cancelEnrollmentDestination() {
        guard isChoosingEnrollmentDestination else { return }
        isChoosingEnrollmentDestination = false
        cancelEnrollmentDestinationHandler()
    }
}
#endif
