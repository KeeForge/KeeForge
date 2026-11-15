#if os(macOS)
import XCTest
@testable import KeeForge

@MainActor
final class MacWindowRestorationStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: MacWindowRestorationStore!
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
    private let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let minimum = CGSize(width: 400, height: 300)

    override func setUp() async throws {
        suiteName = "MacWindowRestorationStoreTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)!
        store = MacWindowRestorationStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
    }

    private func reference(_ provider: String? = nil) -> DatabaseReference {
        var reference = DatabaseReference(id: UUID(), filename: "private.kdbx", isQuickLaunch: false, addedAt: .now)
        if let provider {
            reference.source = .cloud(CloudSyncMetadata(provider: provider, accountId: "account", fileId: "file",
                displayPath: "/private", remoteContentHash: nil, remoteModifiedAt: nil, lastSyncedAt: nil, lastSyncIssue: nil))
        }
        return reference
    }

    private func topology(_ ids: [UUID], launcher: Bool = false, front: UUID? = nil) -> MacWindowRestorationStore.Topology {
        .init(databaseWindows: ids.map { .init(databaseID: $0, frame: frame) },
            databasesWindowOpen: launcher, databasesWindowFrame: frame, frontmostDatabaseID: front)
    }

    private func plan(_ references: [DatabaseReference] = [], screens: [CGRect]? = nil, quick: UUID? = nil,
                      explicit: [UUID] = []) -> MacWindowRestorationStore.Plan {
        store.restorationPlan(knownDatabases: references, screens: screens ?? [screen],
            databaseWindowMinimumSize: minimum, databasesWindowMinimumSize: minimum, defaultDatabasesWindowFrame: frame, quickLaunchDatabaseID: quick, explicitOpenRequests: explicit)
    }

    func testRoundTripPreservesOrderFramesLauncherAndFrontWithLockedWindows() throws {
        let a = reference(), b = reference()
        var saved = topology([b.id, a.id], launcher: true, front: a.id)
        saved.databaseWindows[0] = .init(databaseID: b.id, frame: CGRect(x: 20, y: 30, width: 700, height: 500))
        store.recordTopology(saved)
        store = MacWindowRestorationStore(defaults: defaults)
        let result = plan([a, b])
        XCTAssertEqual(result.databaseWindows.map(\.databaseID), [b.id, a.id])
        XCTAssertEqual(result.databaseWindows.map(\.frame), saved.databaseWindows.map(\.frame))
        XCTAssertTrue(result.databaseWindows.allSatisfy(\.isLocked))
        XCTAssertEqual(result.frontmostDatabaseID, a.id)
        XCTAssertTrue(result.showDatabasesWindow)
        XCTAssertEqual(result.databasesWindowFrame, frame)
        let data = try XCTUnwrap(defaults.data(forKey: MacWindowRestorationStore.storageKey))
        XCTAssertEqual(try JSONDecoder().decode(MacWindowRestorationStore.Topology.self, from: data), saved)
    }

    func testMalformedAndIncompleteRecordsAreAbsent() {
        for data in [Data("broken".utf8), Data("{}".utf8), Data("{\"databaseWindows\":[]}".utf8)] {
            defaults.set(data, forKey: MacWindowRestorationStore.storageKey)
            let result = plan()
            XCTAssertTrue(result.databaseWindows.isEmpty)
            XCTAssertTrue(result.showDatabasesWindow)
            XCTAssertNil(result.frontmostDatabaseID)
            XCTAssertEqual(result.databasesWindowFrame, frame)
        }
    }

    func testDuplicateMissingAndUnsupportedReferencesAreDropped() {
        let local = reference(), webDAV = reference("webdav"), ftp = reference("ftp")
        let unsupported = [reference("dropbox"), reference("onedrive"), reference("future")]
        let missing = UUID()
        var saved = topology([local.id, local.id, missing] + unsupported.map(\.id) + [webDAV.id, ftp.id], front: missing)
        saved.databaseWindows[1] = .init(databaseID: local.id, frame: .zero)
        store.recordTopology(saved)
        let result = plan([local, webDAV, ftp] + unsupported)
        XCTAssertEqual(result.databaseWindows.map(\.databaseID), [local.id, webDAV.id, ftp.id])
        XCTAssertEqual(result.databaseWindows.first?.frame, frame)
        XCTAssertNil(result.frontmostDatabaseID)
        XCTAssertFalse(result.showDatabasesWindow)
    }

    func testFramesFitOneAndTwoScreens() {
        let reference = reference()
        let second = CGRect(x: 1500, y: -200, width: 1000, height: 800)
        let cases: [(CGRect, [CGRect], CGRect)] = [
            (CGRect(x: -900, y: -700, width: 800, height: 600), [screen], CGRect(x: 0, y: 0, width: 800, height: 600)),
            (CGRect(x: 100, y: 100, width: 2000, height: 1600), [screen], screen),
            (CGRect(x: 100, y: 100, width: 10, height: 20), [screen], CGRect(x: 100, y: 100, width: 400, height: 300)),
            (CGRect(x: 2700, y: -300, width: 800, height: 600), [screen, second], CGRect(x: 1700, y: -200, width: 800, height: 600)),
            (CGRect(x: 1600, y: -100, width: 1600, height: 1400), [screen, second], second),
            (CGRect(x: 2400, y: 500, width: 10, height: 20), [screen, second], CGRect(x: 2100, y: 300, width: 400, height: 300))
        ]
        for (input, screens, expected) in cases {
            var saved = topology([reference.id], launcher: true)
            saved.databaseWindows[0] = .init(databaseID: reference.id, frame: input)
            saved.databasesWindowFrame = input
            store.recordTopology(saved)
            let result = plan([reference], screens: screens)
            XCTAssertEqual(result.databaseWindows.first?.frame, expected)
            XCTAssertEqual(result.databasesWindowFrame, expected)
        }
    }

    func testSmallScreenAndNoScreen() {
        let reference = reference()
        store.recordTopology(topology([reference.id]))
        let small = CGRect(x: -200, y: 0, width: 200, height: 150)
        XCTAssertEqual(plan([reference], screens: [small]).databaseWindows.first?.frame, small)
        XCTAssertEqual(plan([reference], screens: []).databaseWindows.first?.frame, frame)
    }

    func testLauncherFallbackForAbsentEmptyOrPrunedTopology() {
        XCTAssertTrue(plan().showDatabasesWindow)
        store.recordTopology(topology([]))
        XCTAssertTrue(plan().showDatabasesWindow)
        store.recordTopology(topology([UUID()]))
        XCTAssertTrue(plan().showDatabasesWindow)
        let reference = reference()
        store.recordTopology(topology([reference.id]))
        XCTAssertFalse(plan([reference]).showDatabasesWindow)
        store.recordTopology(topology([reference.id], launcher: true))
        XCTAssertTrue(plan([reference]).showDatabasesWindow)
    }

    func testDatabaseAndDatabasesWindowsUseTheirOwnMinimumSizes() {
        let reference = reference()
        var saved = topology([reference.id], launcher: true)
        let tiny = CGRect(x: 10, y: 10, width: 100, height: 100)
        saved.databaseWindows[0] = .init(databaseID: reference.id, frame: tiny)
        saved.databasesWindowFrame = tiny
        store.recordTopology(saved)
        let result = store.restorationPlan(knownDatabases: [reference], screens: [screen],
            databaseWindowMinimumSize: CGSize(width: 900, height: 650), databasesWindowMinimumSize: CGSize(width: 600, height: 650),
            defaultDatabasesWindowFrame: frame, quickLaunchDatabaseID: nil, explicitOpenRequests: [])
        XCTAssertEqual(result.databaseWindows.first?.frame, CGRect(x: 10, y: 10, width: 900, height: 650))
        XCTAssertEqual(result.databasesWindowFrame, CGRect(x: 10, y: 10, width: 600, height: 650))
    }

    func testDatabasesShowsWhenRecordedOpenOrWhenNothingElseOpensAWindow() {
        let a = reference()
        XCTAssertTrue(plan([a]).showDatabasesWindow)
        XCTAssertFalse(plan([a], quick: a.id).showDatabasesWindow, "Quick Launch opens a window")
        XCTAssertFalse(plan([a], explicit: [a.id]).showDatabasesWindow, "An incoming file opens a window")
        XCTAssertTrue(plan([a], explicit: [UUID()]).showDatabasesWindow, "An unknown file opens nothing")
        store.recordTopology(topology([], launcher: true))
        XCTAssertTrue(plan([a], quick: a.id).showDatabasesWindow)
    }

    func testQuickLaunchRequiresNoRestoredWindowAndNoExplicitRequest() {
        let a = reference(), b = reference(), unsupported = reference("dropbox")
        XCTAssertEqual(plan([a], quick: a.id).quickLaunchDatabaseID, a.id)
        store.recordTopology(topology([UUID()]))
        XCTAssertEqual(plan([a], quick: a.id).quickLaunchDatabaseID, a.id)
        store.recordTopology(topology([a.id]))
        XCTAssertNil(plan([a, b], quick: b.id).quickLaunchDatabaseID)
        store.recordTopology(topology([]))
        XCTAssertNil(plan([a, b], quick: a.id, explicit: [b.id]).quickLaunchDatabaseID)
        XCTAssertNil(plan([a], quick: a.id, explicit: [UUID()]).quickLaunchDatabaseID)
        XCTAssertNil(plan([unsupported], quick: unsupported.id).quickLaunchDatabaseID)
        XCTAssertNil(plan([a], quick: UUID()).quickLaunchDatabaseID)
    }

    func testExplicitOpenFrontsRestoredDatabaseWithoutAnotherWindow() {
        let a = reference(), b = reference(), unsupported = reference("onedrive")
        store.recordTopology(topology([a.id], front: a.id))
        let result = plan([a, b, unsupported], explicit: [a.id, b.id, b.id, unsupported.id, UUID()])
        XCTAssertEqual(result.databaseWindows.map(\.databaseID), [a.id])
        XCTAssertEqual(result.explicitOpenRequests, [.front(a.id), .open(b.id), .front(b.id)])
        XCTAssertEqual(result.frontmostDatabaseID, a.id)
    }

    func testTerminationPreservesSnapshotAndCancellationResumesRecording() {
        let a = reference(), b = reference()
        store.recordTopology(topology([a.id, b.id], launcher: true, front: b.id))
        let snapshot = defaults.data(forKey: MacWindowRestorationStore.storageKey)
        store.beginTermination()
        store.recordTopology(topology([a.id]))
        store.recordTopology(topology([]))
        XCTAssertEqual(defaults.data(forKey: MacWindowRestorationStore.storageKey), snapshot)
        store.cancelTermination()
        store.recordTopology(topology([a.id]))
        XCTAssertEqual(plan([a, b]).databaseWindows.map(\.databaseID), [a.id])
        store.recordTopology(topology([]))
        XCTAssertTrue(plan([a, b]).databaseWindows.isEmpty)
    }

    func testJSONContainsOnlyAllowedRecordFields() throws {
        let id = UUID()
        store.recordTopology(topology([id], front: id))
        let data = try XCTUnwrap(defaults.data(forKey: MacWindowRestorationStore.storageKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["databaseWindows", "databasesWindowOpen", "databasesWindowFrame", "frontmostDatabaseID"])
        let windows = try XCTUnwrap(json["databaseWindows"] as? [[String: Any]])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(Set(windows[0].keys), ["databaseID", "frame"])
        XCTAssertEqual(windows[0]["databaseID"] as? String, id.uuidString)
        XCTAssertTrue(json["databasesWindowOpen"] is Bool)
        XCTAssertEqual(json["frontmostDatabaseID"] as? String, id.uuidString)
        XCTAssertEqual(windows[0]["frame"] as? [[Double]], [[100, 100], [800, 600]])
        XCTAssertEqual(json["databasesWindowFrame"] as? [[Double]], [[100, 100], [800, 600]])
    }

    func testSplitGeometryNamesAndRemovalAreDatabaseScoped() {
        let a = UUID(), b = UUID()
        let aName = MacWindowRestorationStore.splitViewAutosaveName(for: a)
        let bName = MacWindowRestorationStore.splitViewAutosaveName(for: b)
        XCTAssertEqual(aName, "MacDatabaseWorkspace.\(a.uuidString)")
        XCTAssertNotEqual(aName, bName)
        defaults.set(["geometry"], forKey: "NSSplitView Subview Frames \(aName)")
        defaults.set(["other"], forKey: "NSSplitView Subview Frames \(bName)")
        store.recordTopology(topology([b]))
        let snapshot = defaults.data(forKey: MacWindowRestorationStore.storageKey)
        store.removeSavedGeometry(for: a)
        XCTAssertNil(defaults.object(forKey: "NSSplitView Subview Frames \(aName)"))
        XCTAssertEqual(defaults.stringArray(forKey: "NSSplitView Subview Frames \(bName)"), ["other"])
        XCTAssertEqual(defaults.data(forKey: MacWindowRestorationStore.storageKey), snapshot)
    }
}
#endif
