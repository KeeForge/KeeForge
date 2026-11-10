import Foundation
import XCTest
@testable import KDBXXML

/// Known answers from payloads other implementations wrote; the expected
/// values come from `TestFixtures/README.md`, not from this package's writer.
final class FixtureReadTests: XCTestCase {
    func test_kitchenSink_readsPyKeePassTree() throws {
        let document = try Fixture.payload("kitchen-sink").read()
        let top = try XCTUnwrap(document.root.groups.first)
        XCTAssertEqual(document.root.groups.count, 1)
        XCTAssertEqual(top.name, "Root")
        XCTAssertEqual(top.groups.map(\.name), [
            "Tagged", "Archive", "Secrets", "Icons", "Projects",
            "Empty Tags Group", "Plain Group", "Attachments", "Round Trip", "Recycle Bin",
        ])
        XCTAssertEqual(document.meta.maintenanceHistoryDays, 365)
        XCTAssertEqual(document.meta.historyMaxItems, 10)
        XCTAssertEqual(document.meta.historyMaxSize, 6_291_456)
        XCTAssertEqual(document.meta.recycleBinUUID, top.groups.last?.uuid)
    }

    func test_kitchenSink_unmasksEveryProtectedValueInDocumentOrder() throws {
        let top = try XCTUnwrap(Fixture.payload("kitchen-sink").read().root.groups.first)
        let passwords = Dictionary(
            allEntries(top).map { (field($0, "Title") ?? "", field($0, "Password")) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(passwords["Router Admin"], "TagRouterSecret1")
        XCTAssertEqual(passwords["Old Backup"], "TagArchiveSecret4")
        XCTAssertEqual(passwords["Protected Custom"], "fixture-password")
        XCTAssertEqual(passwords["Alpha Login"], "GroupTagAlpha1")
        XCTAssertEqual(passwords["Beta Login"], "GroupTagBeta2")
        XCTAssertEqual(passwords["Delta Login"], "GroupTagDelta4")
        XCTAssertEqual(passwords["Trashed Login"], "GroupTagTrashed5")
        XCTAssertEqual(passwords["Controlled Unknowns"], "roundtrip-pass")

        let secrets = try XCTUnwrap(top.groups.first { $0.name == "Secrets" })
        let custom = try XCTUnwrap(secrets.entries.first { field($0, "Title") == "Protected Custom" })
        XCTAssertEqual(custom.strings.first { $0.key == "API Token" },
                       KDBXDocument.Field(key: "API Token", value: "custom-secret", isProtected: true))
        XCTAssertEqual(custom.history.count, 1)
        XCTAssertEqual(custom.history.first.flatMap { field($0, "API Token") }, "custom-secret")
        let totp = try XCTUnwrap(secrets.entries.first { field($0, "Title") == "TOTP Login" })
        XCTAssertTrue(try XCTUnwrap(field(totp, "otp")).contains("secret=JBSWY3DPEHPK3PXP"))
    }

    func test_kitchenSink_readsGroupTagsInEveryState() throws {
        let top = try XCTUnwrap(Fixture.payload("kitchen-sink").read().root.groups.first)
        let byName = Dictionary(uniqueKeysWithValues: allGroups(top).map { ($0.name, $0) })
        XCTAssertEqual(byName["Projects"]?.tags, ["team", "shared"], "pykeepass joins with ;")
        XCTAssertEqual(byName["Empty Tags Group"]?.tags, [])
        XCTAssertEqual(try XCTUnwrap(byName["Plain Group"]).tags, nil)
        XCTAssertEqual(byName["Projects"]?.notes,
                       "Group notes ride along as unknown XML next to the structured Tags element.")
        let router = allEntries(top).first { field($0, "Title") == "Router Admin" }
        XCTAssertEqual(router?.tags, ["shared", "Work", "Personal Notes"])
    }

    func test_kitchenSink_readsAttachmentsAndCustomIcons() throws {
        let document = try Fixture.payload("kitchen-sink").read()
        let top = try XCTUnwrap(document.root.groups.first)
        let multi = try XCTUnwrap(allEntries(top).first { field($0, "Title") == "Multi Attachment Entry" })
        XCTAssertEqual(Set(multi.binaries.map(\.key)), ["note-ü.txt", "pixel.png"])

        let icons = document.meta.customIcons
        let badgeIcon = try XCTUnwrap(UUID(uuidString: "4D9C2B1E-7A35-4E68-9B0D-52F16C8A3E77"))
        let namedIcon = try XCTUnwrap(UUID(uuidString: "6B1F0E3A-2C4D-4E5F-8A9B-0C1D2E3F4A5B"))
        XCTAssertEqual(icons[badgeIcon]?.data.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertNil(icons[badgeIcon]?.name)
        XCTAssertEqual(icons[namedIcon]?.name, "Foreign Named Icon")
        let badge = allEntries(top).first { field($0, "Title") == "Custom Badge" }
        XCTAssertEqual(badge?.customIconUUID, badgeIcon)
    }

    func test_kitchenSink_keepsOpaqueXMLInAwkwardPositions() throws {
        let top = try XCTUnwrap(Fixture.payload("kitchen-sink").read().root.groups.first)
        let roundTrip = try XCTUnwrap(allEntries(top).first { field($0, "Title") == "Controlled Unknowns" })
        let customData = try XCTUnwrap(roundTrip.unknownXML.nodes.first { $0.elementName == "CustomData" })
        XCTAssertTrue(customData.xml.contains("RoundTripEntryValue-Expected"))
        XCTAssertTrue(roundTrip.unknownXML.nodes.contains { $0.elementName == "AutoType" })
        let trashed = try XCTUnwrap(allEntries(top).first { field($0, "Title") == "Trashed Login" })
        XCTAssertTrue(trashed.unknownXML.nodes.contains { $0.elementName == "PreviousParentGroup" })
    }

    func test_keePassXC_readsPrettyPrintedKDBX41() throws {
        let document = try Fixture.payload("keepassxc-recycled").read()
        let top = try XCTUnwrap(document.root.groups.first)
        XCTAssertEqual(top.groups.map(\.name), ["Work", "Recycle Bin"])
        XCTAssertEqual(top.notes, "", "KeePassXC writes an empty <Notes/>")
        XCTAssertEqual(top.enableSearching, .inherit)
        XCTAssertNotNil(top.times.locationChanged)
        let recycled = try XCTUnwrap(allEntries(top).first { field($0, "Title") == "Recycled Login" })
        XCTAssertEqual(field(recycled, "Password"), "RecycledLoginSecret1")
        XCTAssertEqual(document.meta.recycleBinUUID, top.groups.last?.uuid)
        // KeePassXC's own <Times> order puts LastModificationTime first.
        XCTAssertNotNil(recycled.times.creationTime)
        XCTAssertNotNil(recycled.times.lastModificationTime)
        XCTAssertFalse(recycled.expires)
        XCTAssertNotNil(recycled.expiryTime)
    }

    func test_keePassXC_customDataTimestampsDoNotReplaceMetaOrEntryTimes() throws {
        let document = try Fixture.payload("keepassxc-recycled").read()
        let customData = try XCTUnwrap(document.meta.unknownXML.nodes.first { $0.elementName == "CustomData" })
        XCTAssertTrue(customData.xml.contains("<LastModificationTime>6Lx84g4AAAA=</LastModificationTime>"))
    }

    func test_legacyKDBX31_readsISODatesAndSalsa20() throws {
        let payload = try Fixture.payload("legacy-kdbx31")
        XCTAssertEqual(payload.streamID, 2)
        let document = try payload.read()
        let top = try XCTUnwrap(document.root.groups.first)
        XCTAssertEqual(top.name, "Passwords")
        XCTAssertEqual(top.groups.map(\.name), ["Social", "Work"])
        XCTAssertEqual(top.times.creationTime, ISO8601DateFormatter().date(from: "2026-02-14T03:41:59Z"))
        let twitter = try XCTUnwrap(allEntries(top).first { field($0, "Title") == "Twitter" })
        XCTAssertEqual(field(twitter, "Password"), "tw1tterP@ss!")
        XCTAssertTrue(document.meta.unknownXML.nodes.contains { $0.elementName == "Binaries" })
    }
}

func allEntries(_ group: KDBXDocument.Group) -> [KDBXDocument.Entry] {
    group.entries + group.groups.flatMap(allEntries)
}

func allGroups(_ group: KDBXDocument.Group) -> [KDBXDocument.Group] {
    [group] + group.groups.flatMap(allGroups)
}

func field(_ entry: KDBXDocument.Entry, _ key: String) -> String? {
    entry.strings.last { $0.key == key }?.value
}
