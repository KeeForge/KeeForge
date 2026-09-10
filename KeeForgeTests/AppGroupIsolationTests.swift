import XCTest
@testable import KeeForge

/// Unit-test isolation from the real App Group container.
///
/// `KeeForgeMacTests` is hosted by the real signed Mac app, so before
/// `AppGroupContainer` existed a Mac run operated on
/// `~/Library/Group Containers/group.com.keevault.shared` — the developer's own
/// storage — and the `DatabaseListStore.clearAll()` in several suites' `setUp`
/// deleted their database list and on-device backups (observed 2026-09-09).
/// These tests fail if the suite is ever pointed back at real shared storage.
final class AppGroupIsolationTests: XCTestCase {
    func testGroupContainerResolvesToATemporaryDirectoryUnderTest() throws {
        XCTAssertTrue(
            AppGroupContainer.isRedirectedForTesting,
            "The unit-test host is not redirecting App Group storage; a run would write to the real container"
        )

        let container = AppGroupContainer.url
        XCTAssertTrue(
            container.resolvingSymlinksInPath().path
                .hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path),
            "\(container.path) is not a temporary directory"
        )

        XCTAssertNotNil(
            AppGroupContainer.resolvedURL,
            "resolvedURL must stay non-nil under test, or MacTransitionNoticeService reads a denied container"
        )

        let live = try XCTUnwrap(
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupContainer.identifier),
            "The test host lost its App Group entitlement, so this suite can no longer prove isolation"
        )
        XCTAssertFalse(
            container.resolvingSymlinksInPath().path
                .hasPrefix(live.resolvingSymlinksInPath().path),
            "App Group storage still resolves inside the real container at \(live.path)"
        )
    }

    func testSharedDefaultsResolveToATemporarySuiteUnderTest() throws {
        let key = "KeeForge.appGroupIsolationProbe.\(UUID().uuidString)"
        AppGroupContainer.defaults.set(true, forKey: key)
        defer { AppGroupContainer.defaults.removeObject(forKey: key) }

        let live = try XCTUnwrap(UserDefaults(suiteName: AppGroupContainer.identifier))
        XCTAssertNil(
            live.object(forKey: key),
            "Shared defaults writes are landing in the real App Group suite"
        )
    }

    func testEveryGroupContainerWriterResolvesInsideTheRedirectedContainer() throws {
        let container = AppGroupContainer.url.resolvingSymlinksInPath().path
        let url = try makeTemporaryFileURL(name: "isolation.kdbx")
        let reference = try DatabaseListStore.add(url: url)
        defer { DatabaseListStore.clearAll() }

        let writers: [(String, URL)] = [
            ("DatabaseListStore backups", DatabaseListStore.databaseBackupDirectoryURL(for: reference)),
            ("DatabaseListStore cached copy", try XCTUnwrap(DatabaseListStore.cachedDatabaseURL(for: reference.id))),
            ("SharedVaultStore database cache", SharedVaultStore.databaseCacheDirectory),
            ("SharedVaultStore cloud cache", SharedVaultStore.cloudCacheDirectory),
            ("PendingUploadQueue", PendingUploadQueue.Environment.live.appGroupContainerURL()),
        ]

        for (name, writerURL) in writers {
            XCTAssertTrue(
                writerURL.resolvingSymlinksInPath().path.hasPrefix(container),
                "\(name) writes to \(writerURL.path), outside the redirected container \(container)"
            )
        }
    }

    func testClearAllEmptiesTheRedirectedContainerAndLeavesTheRealOneIntact() throws {
        let liveEntriesBefore = liveContainerEntries()

        let url = try makeTemporaryFileURL(name: "clear-all.kdbx")
        _ = try DatabaseListStore.add(url: url)
        let listURL = AppGroupContainer.url.appendingPathComponent("database-list.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: listURL.path))

        DatabaseListStore.clearAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: listURL.path))

        let liveEntriesAfter = liveContainerEntries()
        XCTAssertTrue(
            liveEntriesBefore.isSubset(of: liveEntriesAfter),
            """
            DatabaseListStore.clearAll() deleted \(liveEntriesBefore.subtracting(liveEntriesAfter)) \
            from the real App Group container
            """
        )
    }

    private func liveContainerEntries() -> Set<String> {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupContainer.identifier
        ), let entries = try? FileManager.default.contentsOfDirectory(atPath: container.path) else {
            return []
        }
        return Set(entries)
    }

    private func makeTemporaryFileURL(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        return url
    }
}
