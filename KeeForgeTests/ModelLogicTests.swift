import XCTest
@testable import KeeForge

final class ModelLogicTests: XCTestCase {
    func testKPGroupAllEntriesFlattensRecursively() {
        let entry1 = KPEntry(title: "one")
        let entry2 = KPEntry(title: "two")
        let entry3 = KPEntry(title: "three")

        let deepGroup = KPGroup(name: "deep", entries: [entry3])
        let childGroup = KPGroup(name: "child", entries: [entry2], groups: [deepGroup])
        let root = KPGroup(name: "root", entries: [entry1], groups: [childGroup])

        let titles = root.allEntries.map(\.title)

        XCTAssertEqual(titles, ["one", "two", "three"])
    }

    func testKPEntrySystemIconNameMapsKnownAndDefaultIDs() {
        XCTAssertEqual(KPEntry(iconID: 0).systemIconName, "key.fill")
        XCTAssertEqual(KPEntry(iconID: 1).systemIconName, "globe")
        XCTAssertEqual(KPEntry(iconID: 62).systemIconName, "creditcard.fill")
        XCTAssertEqual(KPEntry(iconID: 68).systemIconName, "at")
        XCTAssertEqual(KPEntry(iconID: 999).systemIconName, "key.fill")
    }

    func testKPEntryIsExpiredRequiresEnabledPastExpiryTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let past = now.addingTimeInterval(-1)

        XCTAssertTrue(
            KPEntry(expires: true, expiryTime: past).isExpired(at: now)
        )
        XCTAssertFalse(
            KPEntry(expires: true, expiryTime: now.addingTimeInterval(1)).isExpired(at: now)
        )
        XCTAssertFalse(
            KPEntry(expires: false, expiryTime: past).isExpired(at: now)
        )
        XCTAssertFalse(KPEntry(expires: true, expiryTime: nil).isExpired(at: now))
        XCTAssertEqual(KPEntry(expires: true, expiryTime: past).enabledExpiryTime, past)
        XCTAssertNil(KPEntry(expires: false, expiryTime: past).enabledExpiryTime)
    }

    func testKPGroupSystemIconNameMapsKnownAndDefaultIDs() {
        XCTAssertEqual(KPGroup(name: "a", iconID: 0).systemIconName, "key.fill")
        XCTAssertEqual(KPGroup(name: "a", iconID: 1).systemIconName, "globe")
        XCTAssertEqual(KPGroup(name: "a", iconID: 2).systemIconName, "exclamationmark.triangle")
        XCTAssertEqual(KPGroup(name: "a", iconID: 3).systemIconName, "server.rack")
        XCTAssertEqual(KPGroup(name: "a", iconID: 43).systemIconName, "trash")
        XCTAssertEqual(KPGroup(name: "a", iconID: 48).systemIconName, "folder.fill")
        XCTAssertEqual(KPGroup(name: "a", iconID: 49).systemIconName, "folder.fill")
        XCTAssertEqual(KPGroup(name: "a", iconID: 999).systemIconName, "folder.fill")
    }

    func testKPEntryHashableAndEqualityUseOnlyID() {
        let id = UUID()
        let lhs = KPEntry(id: id, title: "first")
        let rhs = KPEntry(id: id, title: "second")

        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(Set([lhs, rhs]).count, 1)
    }

    func testKPGroupHashableAndEqualityUseOnlyID() {
        let id = UUID()
        let lhs = KPGroup(id: id, name: "first")
        let rhs = KPGroup(id: id, name: "second", entries: [KPEntry(title: "x")])

        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(Set([lhs, rhs]).count, 1)
    }
}
