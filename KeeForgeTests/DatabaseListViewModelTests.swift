import XCTest
@testable import KeeForge

@MainActor
final class DatabaseListViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DatabaseListStore.clearAll()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() {
        DatabaseListStore.clearAll()
        SharedVaultStore.clearBookmark()
        super.tearDown()
    }

    func testMakeRowStatusUsesAccessCheckerResultForReachability() {
        let unreachablePathURL = URL(fileURLWithPath: "/tmp/provider-backed/provider.kdbx")

        let status = DatabaseListViewModel.makeRowStatus(
            resolvedURL: unreachablePathURL,
            hasStoredKey: true,
            accessChecker: { _ in true }
        )

        XCTAssertTrue(status.hasStoredKey)
        XCTAssertFalse(status.hasAccessIssue)
    }

    func testMakeRowStatusMarksMissingResolvedURLAsUnavailable() {
        let status = DatabaseListViewModel.makeRowStatus(
            resolvedURL: nil,
            hasStoredKey: false
        )

        XCTAssertFalse(status.hasStoredKey)
        XCTAssertTrue(status.hasAccessIssue)
    }

    func testSingleDatabaseDoesNotAutoOpenWhenQuickLaunchIsOff() throws {
        _ = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        let viewModel = DatabaseListViewModel()

        XCTAssertNil(viewModel.databaseToAutoOpenOnLaunch())
    }

    func testSingleDatabaseAutoOpensWhenQuickLaunchIsOn() throws {
        var reference = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "personal.kdbx"))
        reference.isQuickLaunch = true
        DatabaseListStore.update(reference)

        let viewModel = DatabaseListViewModel()

        XCTAssertEqual(viewModel.databaseToAutoOpenOnLaunch()?.id, reference.id)
        XCTAssertNil(viewModel.databaseToAutoOpenOnLaunch(), "Initial launch selection should only be consumed once")
    }

    func testToggleQuickLaunchClearsPreviousSelection() throws {
        var first = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "one.kdbx"))
        let second = try DatabaseListStore.add(url: makeTemporaryFileURL(name: "two.kdbx"))
        first.isQuickLaunch = true
        DatabaseListStore.update(first)

        let viewModel = DatabaseListViewModel()
        viewModel.toggleQuickLaunch(for: second)

        let updatedFirst = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == first.id }))
        let updatedSecond = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == second.id }))

        XCTAssertFalse(updatedFirst.isQuickLaunch)
        XCTAssertTrue(updatedSecond.isQuickLaunch)
    }

    func testPickerPresentationStateKeepsTargetUntilCompletion() {
        var state = PickerPresentationState<String>()

        state.present("database")
        state.updatePresentation(false)

        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(state.activeTarget, "database")
        XCTAssertEqual(state.consumeActiveTarget(), "database")
        XCTAssertNil(state.activeTarget)
        XCTAssertFalse(state.isPresented)
    }

    private func makeTemporaryFileURL(name: String, contents: Data = Data("fixture".utf8)) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try contents.write(to: url)
        return url
    }
}
