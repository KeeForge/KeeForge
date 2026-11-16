#if os(macOS)
import XCTest
@testable import KeeForge

@MainActor
final class BrowserHostInstallerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite = ""
    private var granted: URL?
    private var cancel = false
    private var stale = false
    private var startAllowed = true
    private var starts = 0
    private var stops = 0
    private var requests: [BrowserHostInstaller.FolderGrantRequest] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "BrowserHostInstallerTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        XCTAssertEqual(starts, stops)
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private func installer(app: String = "/Applications/KeeForge.app", installed: Bool = true, origins: [String] = ["chrome-extension://test/"]) -> BrowserHostInstaller {
        BrowserHostInstaller(
            defaults: defaults, home: root, appBundle: URL(fileURLWithPath: app), chromiumOrigins: origins,
            bookmarks: .init(
                create: { Data($0.path.utf8) },
                resolve: { [unowned self] in (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), stale) },
                start: { [unowned self] _ in if startAllowed { starts += 1 }; return startAllowed },
                stop: { [unowned self] _ in stops += 1 }
            ),
            isInstalled: { _ in installed },
            grantFolder: { [unowned self] request in
                requests.append(request)
                return cancel ? nil : (granted ?? request.directoryToGrant)
            }
        )
    }

    private func prepare(_ browser: HostBrowser = .chrome, manifestFolder: Bool = true) throws -> URL {
        let directory = root.appendingPathComponent(browser.manifestRelativeDirectory)
        try FileManager.default.createDirectory(at: manifestFolder ? directory : directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        return directory
    }

    private func manifestURL(_ directory: URL) -> URL { directory.appendingPathComponent("com.keevault.browser.json") }

    private func assertError(_ expected: BrowserHostInstallerError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? BrowserHostInstallerError, expected) }
    }

    func testManifestExactKeysAndValuesPerFlavour() throws {
        let subject = installer()
        for browser in HostBrowser.allCases {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: subject.manifest(for: browser)) as? NSDictionary)
            let expected: NSDictionary = [
                "name": "com.keevault.browser", "description": "KeeForge browser integration",
                "path": "/Applications/KeeForge.app/Contents/MacOS/keeforge-browser-host", "type": "stdio",
                browser.isFirefox ? "allowed_extensions" : "allowed_origins": browser.isFirefox ? ["browser-extension@keeforge.com"] : ["chrome-extension://test/"]
            ]
            XCTAssertEqual(json, expected)
        }
    }

    func testSupportedBrowserDirectoriesAndDetectionIdentifiers() {
        XCTAssertEqual(HostBrowser.allCases.count, 8)
        XCTAssertEqual(Set(HostBrowser.allCases.flatMap(\.bundleIdentifiers)).count, 8)
        XCTAssertEqual(HostBrowser.arc.manifestRelativeDirectory, "Library/Application Support/Arc/User Data/NativeMessagingHosts")
        XCTAssertEqual(HostBrowser.chromeBeta.bundleIdentifiers, ["com.google.Chrome.beta"])
        XCTAssertEqual(HostBrowser.firefox.manifestRelativeDirectory, "Library/Application Support/Mozilla/NativeMessagingHosts")
    }

    func testNotInstalledAndNotSetUpStates() {
        XCTAssertEqual(installer(installed: false).state(for: .chrome), .notInstalled)
        XCTAssertEqual(installer().state(for: .chrome), .notSetUp)
    }

    func testSetUpWritesAndPersistsGrantAcrossInstallerInstances() async throws {
        let directory = try prepare()
        let subject = installer()
        try await subject.setUp(.chrome)
        XCTAssertEqual(requests.first?.directoryToGrant.path, directory.path)
        XCTAssertEqual(try Data(contentsOf: manifestURL(directory)), try subject.manifest(for: .chrome))
        XCTAssertEqual(installer().state(for: .chrome), .ready)
    }

    func testWrongFolderRefused() async throws {
        let directory = try prepare()
        granted = root
        await assertError(.wrongFolder) { try await installer().setUp(.chrome) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL(directory).path))
        XCTAssertEqual(installer().state(for: .chrome), .notSetUp)
    }

    func testCancelledGrant() async throws {
        _ = try prepare()
        cancel = true
        await assertError(.grantCancelled) { try await installer().setUp(.chrome) }
        XCTAssertEqual(starts, 0)
    }

    func testMissingManifestFolderCreatedUnderParentGrant() async throws {
        let directory = try prepare(manifestFolder: false)
        let subject = installer()
        try await subject.setUp(.chrome)
        XCTAssertEqual(requests.first?.directoryToGrant.path, directory.deletingLastPathComponent().path)
        XCTAssertEqual(installer().state(for: .chrome), .ready)
    }

    func testMissingBrowserParentRefused() async {
        await assertError(.browserParentMissing) { try await installer().setUp(.chrome) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
    }

    func testMissingAndChangedManifestNeedRepair() async throws {
        let directory = try prepare()
        let subject = installer()
        try await subject.setUp(.chrome)
        try FileManager.default.removeItem(at: manifestURL(directory))
        XCTAssertEqual(subject.state(for: .chrome), .needsRepair)
        XCTAssertEqual(subject.repairAll()[.chrome], .ready)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL(directory))) as? [String: Any])
        json["description"] = "outdated"
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL(directory))
        XCTAssertEqual(subject.state(for: .chrome), .needsRepair)
        XCTAssertEqual(subject.repairAll()[.chrome], .ready)
        XCTAssertEqual(requests.count, 1)
    }

    func testRepairAfterAppMovedWithoutPanel() async throws {
        let directory = try prepare()
        try await installer().setUp(.chrome)
        let moved = installer(app: "/Users/test/Applications/KeeForge.app")
        XCTAssertEqual(moved.state(for: .chrome), .needsRepair)
        XCTAssertEqual(moved.repairAll()[.chrome], .ready)
        XCTAssertEqual(try Data(contentsOf: manifestURL(directory)), try moved.manifest(for: .chrome))
        XCTAssertEqual(requests.count, 1)
    }

    func testStaleBookmarkReportsAccessLostAndRepairDoesNotWrite() async throws {
        let directory = try prepare()
        try await installer().setUp(.chrome)
        let original = try Data(contentsOf: manifestURL(directory))
        stale = true
        let moved = installer(app: "/elsewhere/KeeForge.app")
        XCTAssertEqual(moved.state(for: .chrome), .accessLost)
        XCTAssertEqual(moved.repairAll()[.chrome], .accessLost)
        XCTAssertEqual(try Data(contentsOf: manifestURL(directory)), original)
        XCTAssertEqual(requests.count, 1)
    }

    func testLostScopeAndDeletedFolderReportAccessLost() async throws {
        let directory = try prepare()
        let subject = installer()
        try await subject.setUp(.chrome)
        startAllowed = false
        XCTAssertEqual(subject.state(for: .chrome), .accessLost)
        startAllowed = true
        try FileManager.default.removeItem(at: directory)
        XCTAssertEqual(subject.state(for: .chrome), .accessLost)
    }

    func testRemoveOwnedManifestAndBookmark() async throws {
        let directory = try prepare()
        let subject = installer()
        try await subject.setUp(.chrome)
        try subject.remove(.chrome)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL(directory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(subject.state(for: .chrome), .notSetUp)
    }

    func testForeignNameNeverOverwrittenOrRemoved() async throws {
        let directory = try prepare()
        let subject = installer()
        try await subject.setUp(.chrome)
        let foreign = Data(#"{"name":"foreign","path":"/Applications/KeeForge.app/host"}"#.utf8)
        try foreign.write(to: manifestURL(directory))
        XCTAssertEqual(subject.repairAll()[.chrome], .needsRepair)
        await assertError(.foreignManifest) { try await subject.setUp(.chrome) }
        await assertError(.foreignManifest) { try subject.remove(.chrome) }
        XCTAssertEqual(try Data(contentsOf: manifestURL(directory)), foreign)
        XCTAssertEqual(subject.state(for: .chrome), .notSetUp)
    }

    func testRemoveRefusesHostOutsideKeeForgeApp() async throws {
        let directory = try prepare()
        let subject = installer(app: "/Applications/Another.app")
        try await subject.setUp(.chrome)
        await assertError(.foreignManifest) { try subject.remove(.chrome) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL(directory).path))
    }

    func testRemoveAllContinuesAfterLostAccess() async throws {
        let chrome = try prepare()
        let firefox = try prepare(.firefox)
        let subject = installer()
        try await subject.setUp(.chrome)
        try await subject.setUp(.firefox)
        try FileManager.default.removeItem(at: chrome)
        XCTAssertEqual(subject.removeAll()[.chrome], .accessLost)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL(firefox).path))
        XCTAssertEqual(subject.state(for: .chrome), .notSetUp)
        XCTAssertEqual(subject.state(for: .firefox), .notSetUp)
    }

    func testEmptyChromiumListRefusesSetupBeforePanel() async {
        let subject = installer(origins: [])
        XCTAssertEqual(subject.state(for: .chrome), .extensionIDNotConfigured)
        await assertError(.extensionIDNotConfigured) { try await subject.setUp(.chrome) }
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNoThrow(try subject.manifest(for: .firefox))
    }

    func testSymlinkedManifestNeverFollowed() async throws {
        let directory = try prepare()
        let subject = installer()
        try await subject.setUp(.chrome)
        let outside = root.appendingPathComponent("outside.json")
        let original = try subject.manifest(for: .chrome)
        try original.write(to: outside)
        try FileManager.default.removeItem(at: manifestURL(directory))
        try FileManager.default.createSymbolicLink(at: manifestURL(directory), withDestinationURL: outside)
        XCTAssertEqual(subject.repairAll()[.chrome], .needsRepair)
        await assertError(.unsafeManifest) { try await subject.setUp(.chrome) }
        await assertError(.unsafeManifest) { try subject.remove(.chrome) }
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testSymlinkedManifestDirectoryRefused() async throws {
        let directory = try prepare()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        await assertError(.unsafeManifest) { try await installer().setUp(.chrome) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
#endif
