import Foundation
import XCTest
@testable import KDBXXML

/// Known answers for where a spliced element lands: each case checks the
/// recorded position and the XML the writer emits for it.
final class PositionTests: XCTestCase {
    private let uuid = TestID.entry.kdbxBase64String
    private let groupUUID = TestID.group.kdbxBase64String
    private let date = Date(unix: 1_600_000_000)
    private let icon = "<CustomIconUUID>\(TestID.other.kdbxBase64String)</CustomIconUUID>"
    private let parent = "<PreviousParentGroup>\(TestID.group.kdbxBase64String)</PreviousParentGroup>"

    // MARK: - Entry

    func test_entry_customIconFollowsIconID() throws {
        var value = KDBXDocument.Entry(uuid: TestID.entry, strings: [.init(key: "A", value: "a")])
        value.replaceOpaqueChildren(named: "CustomIconUUID", with: [icon])
        XCTAssertEqual(value.unknownXML.nodes, [.init(insertionIndex: 2, xml: icon)])
        XCTAssertEqual(try entryXML(value), """
        <UUID>\(uuid)</UUID><IconID>0</IconID>\(icon)<String><Key>A</Key><Value>a</Value></String>
        """)
    }

    func test_entry_customIconCountsAttachmentsWrittenBeforeIt() throws {
        var value = KDBXDocument.Entry(uuid: TestID.entry, strings: [.init(key: "A", value: "a")])
        value.binaries = [.init(key: "early", ref: 0, insertionIndex: 1), .init(key: "late", ref: 1, insertionIndex: 2)]
        value.replaceOpaqueChildren(named: "CustomIconUUID", with: [icon])
        XCTAssertEqual(value.unknownXML.nodes, [.init(insertionIndex: 3, xml: icon)])
        XCTAssertEqual(try entryXML(value), """
        <UUID>\(uuid)</UUID><Binary><Key>early</Key><Value Ref="0"/></Binary><IconID>0</IconID>\(icon)\
        <Binary><Key>late</Key><Value Ref="1"/></Binary><String><Key>A</Key><Value>a</Value></String>
        """)
    }

    func test_entry_previousParentGroupGoesBetweenTagsAndTimes() throws {
        var value = KDBXDocument.Entry(
            uuid: TestID.entry, tags: ["t"], times: .init(creationTime: date),
            history: [KDBXDocument.Entry(uuid: TestID.entry)]
        )
        value.unknownXML = OpaqueXMLNodes(nodes: [
            .init(insertionIndex: 2, xml: "<ForegroundColor></ForegroundColor>"),
            .init(insertionIndex: 3, xml: "<Vendor></Vendor>"),
        ])
        value.replaceOpaqueChildren(named: "PreviousParentGroup", with: [parent])
        XCTAssertEqual(value.unknownXML.nodes.last, .init(insertionIndex: 3, xml: parent))
        XCTAssertEqual(try entryXML(value), """
        <UUID>\(uuid)</UUID><IconID>0</IconID><ForegroundColor></ForegroundColor><Tags>t</Tags><Vendor></Vendor>\
        \(parent)<Times><CreationTime>\(date.kdbxBase64String)</CreationTime></Times>\
        <History><Entry><UUID>\(uuid)</UUID><IconID>0</IconID></Entry></History>
        """)
    }

    func test_entry_withoutTimesPutsDirectChildrenBeforeTheStrings() throws {
        var value = KDBXDocument.Entry(uuid: TestID.entry, strings: [.init(key: "A", value: "a")])
        value.unknownXML.append(xml: "<OverrideURL></OverrideURL>", insertionIndex: 2)
        value.replaceOpaqueChildren(named: "PreviousParentGroup", with: [parent])
        value.replaceOpaqueChildren(named: "CustomIconUUID", with: [icon])
        XCTAssertEqual(value.unknownXML.nodes.map(\.insertionIndex), [2, 2, 2])
        XCTAssertEqual(try entryXML(value), """
        <UUID>\(uuid)</UUID><IconID>0</IconID>\(icon)<OverrideURL></OverrideURL>\(parent)\
        <String><Key>A</Key><Value>a</Value></String>
        """)
    }

    func test_entry_childAfterAttachmentsFollowsTheAttachmentsAtItsPosition() throws {
        var value = KDBXDocument.Entry(
            uuid: TestID.entry, strings: [.init(key: "A", value: "a")],
            binaries: [.init(key: "f", ref: 0, insertionIndex: 3)],
            history: [KDBXDocument.Entry(uuid: TestID.entry)]
        )
        value.replaceOpaqueChildren(named: "AutoType", with: ["<AutoType></AutoType>"])
        XCTAssertEqual(value.unknownXML.nodes, [.init(insertionIndex: 4, xml: "<AutoType></AutoType>")])
        XCTAssertEqual(try entryXML(value), """
        <UUID>\(uuid)</UUID><IconID>0</IconID><String><Key>A</Key><Value>a</Value></String>\
        <Binary><Key>f</Key><Value Ref="0"/></Binary><AutoType></AutoType>\
        <History><Entry><UUID>\(uuid)</UUID><IconID>0</IconID></Entry></History>
        """)
    }

    func test_entry_unlistedNameTrailsEveryTypedChild() throws {
        var value = KDBXDocument.Entry(
            uuid: TestID.entry, strings: [.init(key: "A", value: "a")],
            history: [KDBXDocument.Entry(uuid: TestID.entry)]
        )
        value.replaceOpaqueChildren(named: "Vendor", with: ["<Vendor></Vendor>"])
        XCTAssertEqual(value.unknownXML.nodes, [.init(insertionIndex: 4, xml: "<Vendor></Vendor>")])
        XCTAssertTrue(try entryXML(value).hasSuffix("</History><Vendor></Vendor>"))
    }

    func test_entry_replacingKeepsTheExistingPositionAndEmptyRemoves() {
        var value = KDBXDocument.Entry(uuid: TestID.entry, tags: [])
        value.unknownXML = OpaqueXMLNodes(nodes: [
            .init(insertionIndex: 0, xml: "<A></A>"),
            .init(insertionIndex: 1, xml: "<CustomIconUUID>old</CustomIconUUID>"),
            .init(path: ["Times"], insertionIndex: 0, xml: "<CustomIconUUID>nested</CustomIconUUID>"),
            .init(insertionIndex: 5, xml: "<CustomIconUUID>duplicate</CustomIconUUID>"),
        ])
        value.replaceOpaqueChildren(named: "CustomIconUUID", with: [icon])
        XCTAssertEqual(value.unknownXML.nodes, [
            .init(insertionIndex: 0, xml: "<A></A>"),
            .init(insertionIndex: 1, xml: icon),
            .init(path: ["Times"], insertionIndex: 0, xml: "<CustomIconUUID>nested</CustomIconUUID>"),
        ])
        value.replaceOpaqueChildren(named: "CustomIconUUID", with: [])
        XCTAssertEqual(value.unknownXML.nodes.map(\.xml), ["<A></A>", "<CustomIconUUID>nested</CustomIconUUID>"])
        value.replaceOpaqueChildren(named: "Missing", with: [])
        XCTAssertEqual(value.unknownXML.nodes.count, 2)
    }

    // MARK: - Times

    func test_times_newChildTakesKeePassOrderAmongItsNeighbors() throws {
        var value = KDBXDocument.Entry(
            uuid: TestID.entry,
            times: .init(creationTime: date, lastModificationTime: date, locationChanged: date)
        )
        value.unknownXML = OpaqueXMLNodes(nodes: [
            .init(path: ["Times"], insertionIndex: 2, xml: "<LastAccessTime></LastAccessTime>"),
            .init(path: ["Times"], insertionIndex: 2, xml: "<Vendor></Vendor>"),
            .init(insertionIndex: 2, xml: "<Expires>direct</Expires>"),
            .init(path: ["Times"], insertionIndex: 1, xml: "<UsageCount>early</UsageCount>"),
            .init(path: ["Times"], insertionIndex: 2, xml: "<UsageCount>0</UsageCount>"),
            .init(path: ["Times"], insertionIndex: 2, xml: "text"),
        ])
        value.replaceOpaqueTimesChildren(named: "ExpiryTime", with: ["<ExpiryTime>x</ExpiryTime>"])
        value.replaceOpaqueTimesChildren(named: "Expires", with: ["<Expires>True</Expires>"])
        XCTAssertEqual(value.unknownXML.nodes.map(\.xml), [
            "<LastAccessTime></LastAccessTime>", "<Vendor></Vendor>", "<Expires>direct</Expires>",
            "<UsageCount>early</UsageCount>", "<ExpiryTime>x</ExpiryTime>", "<Expires>True</Expires>",
            "<UsageCount>0</UsageCount>", "text",
        ])
        let stamp = date.kdbxBase64String
        XCTAssertTrue(try entryXML(value).contains("""
        <Times><CreationTime>\(stamp)</CreationTime><UsageCount>early</UsageCount>\
        <LastModificationTime>\(stamp)</LastModificationTime><LastAccessTime></LastAccessTime><Vendor></Vendor>\
        <ExpiryTime>x</ExpiryTime><Expires>True</Expires><UsageCount>0</UsageCount>text\
        <LocationChanged>\(stamp)</LocationChanged></Times>
        """))
    }

    func test_times_absentTimesIsWrittenForTheNewChild() throws {
        var value = KDBXDocument.Entry(uuid: TestID.entry, tags: ["t"], strings: [.init(key: "A", value: "a")])
        value.replaceOpaqueTimesChildren(named: "Expires", with: ["<Expires>True</Expires>"])
        XCTAssertEqual(value.unknownXML.nodes, [.init(path: ["Times"], insertionIndex: 0, xml: "<Expires>True</Expires>")])
        XCTAssertEqual(try entryXML(value), """
        <UUID>\(uuid)</UUID><IconID>0</IconID><Tags>t</Tags><Times><Expires>True</Expires></Times>\
        <String><Key>A</Key><Value>a</Value></String>
        """)
    }

    func test_times_groupChildFollowsTheTypedDates() throws {
        var value = KDBXDocument.Group(uuid: TestID.group, times: .init(lastModificationTime: date))
        value.replaceOpaqueTimesChildren(named: "ExpiryTime", with: ["<ExpiryTime>x</ExpiryTime>"])
        XCTAssertEqual(value.unknownXML.nodes, [.init(path: ["Times"], insertionIndex: 1, xml: "<ExpiryTime>x</ExpiryTime>")])
        XCTAssertTrue(try groupXML(value).contains(
            "<Times><LastModificationTime>\(date.kdbxBase64String)</LastModificationTime><ExpiryTime>x</ExpiryTime></Times>"
        ))
    }

    // MARK: - Group

    func test_group_previousParentGroupGoesBeforeTags() throws {
        var value = KDBXDocument.Group(
            uuid: TestID.group, notes: "", times: .init(creationTime: date), enableSearching: .disabled, tags: ["t"],
            entries: [KDBXDocument.Entry(uuid: TestID.entry)]
        )
        value.unknownXML = OpaqueXMLNodes(nodes: [
            .init(insertionIndex: 7, xml: "<LastTopVisibleEntry></LastTopVisibleEntry>"),
            .init(insertionIndex: 7, xml: "<CustomData></CustomData>"),
        ])
        value.replaceOpaqueChildren(named: "PreviousParentGroup", with: [parent])
        XCTAssertEqual(value.unknownXML.nodes.map(\.insertionIndex), [7, 7, 7])
        XCTAssertEqual(try groupXML(value), """
        <Group><UUID>\(groupUUID)</UUID><Name></Name><Notes></Notes><IconID>48</IconID>\
        <Times><CreationTime>\(date.kdbxBase64String)</CreationTime></Times><IsExpanded>True</IsExpanded>\
        <EnableSearching>False</EnableSearching><LastTopVisibleEntry></LastTopVisibleEntry>\(parent)\
        <CustomData></CustomData><Tags>t</Tags><Entry><UUID>\(uuid)</UUID><IconID>0</IconID></Entry></Group>
        """)
    }

    func test_group_minimalGroupPutsTheReferenceAfterIsExpanded() throws {
        var value = KDBXDocument.Group(uuid: TestID.group)
        value.replaceOpaqueChildren(named: "PreviousParentGroup", with: [parent])
        XCTAssertEqual(value.unknownXML.nodes, [.init(insertionIndex: 4, xml: parent)])
        XCTAssertEqual(try groupXML(value), """
        <Group><UUID>\(groupUUID)</UUID><Name></Name><IconID>48</IconID><IsExpanded>True</IsExpanded>\(parent)</Group>
        """)
    }

    // MARK: - Meta

    func test_meta_customIconsGoBetweenMemoryProtectionAndTheRecycleBin() throws {
        var meta = KDBXDocument.Meta(recycleBin: .unset, maintenanceHistoryDays: 365, historyMaxItems: 10)
        meta.unknownXML = OpaqueXMLNodes(nodes: [
            .init(insertionIndex: 0, xml: "<Generator>X</Generator>"),
            .init(insertionIndex: 1, xml: "<MemoryProtection></MemoryProtection>"),
            .init(insertionIndex: 1, xml: "<RecycleBinEnabled>True</RecycleBinEnabled>"),
        ])
        meta.replaceOpaqueChildren(named: "CustomIcons", with: ["<CustomIcons></CustomIcons>"])
        XCTAssertEqual(meta.unknownXML.nodes[2], .init(insertionIndex: 1, xml: "<CustomIcons></CustomIcons>"))
        XCTAssertEqual(try write(KDBXDocument(meta: meta)), """
        <KeePassFile><Meta><Generator>X</Generator><MaintenanceHistoryDays>365</MaintenanceHistoryDays>\
        <MemoryProtection></MemoryProtection><CustomIcons></CustomIcons><RecycleBinEnabled>True</RecycleBinEnabled>\
        <RecycleBinUUID>AAAAAAAAAAAAAAAAAAAAAA==</RecycleBinUUID><HistoryMaxItems>10</HistoryMaxItems></Meta>\
        <Root></Root></KeePassFile>
        """)
    }

    func test_meta_customIconsInAnEmptyMetaGoFirst() {
        var meta = KDBXDocument.Meta(historyMaxSize: 1)
        meta.replaceOpaqueChildren(named: "CustomIcons", with: ["<CustomIcons></CustomIcons>"])
        XCTAssertEqual(meta.unknownXML.nodes, [.init(insertionIndex: 0, xml: "<CustomIcons></CustomIcons>")])
    }

    // MARK: - Attachments

    func test_binaryInsertionIndex_countsTheTypedChildrenBeforeTheStrings() throws {
        let bare = KDBXDocument.Entry(uuid: TestID.entry)
        XCTAssertEqual(bare.binaryInsertionIndex(afterStrings: 5), 7)
        var tagged = KDBXDocument.Entry(uuid: TestID.entry, tags: [], times: .init(lastModificationTime: date))
        XCTAssertEqual(tagged.binaryInsertionIndex(afterStrings: 1), 5)
        var timesOnly = KDBXDocument.Entry(uuid: TestID.entry)
        timesOnly.unknownXML.append(xml: "<UsageCount>0</UsageCount>", path: ["Times"], insertionIndex: 0)
        XCTAssertEqual(timesOnly.binaryInsertionIndex(afterStrings: 0), 3)

        tagged.strings = [.init(key: "A", value: "a"), .init(key: "B", value: "b")]
        tagged.binaries = [.init(key: "f", ref: 0, insertionIndex: tagged.binaryInsertionIndex(afterStrings: 1))]
        XCTAssertTrue(try entryXML(tagged).hasSuffix("""
        <String><Key>A</Key><Value>a</Value></String><Binary><Key>f</Key><Value Ref="0"/></Binary>\
        <String><Key>B</Key><Value>b</Value></String>
        """))
    }

    // MARK: - Support

    /// The children of the entry's `<Entry>` element.
    private func entryXML(_ value: KDBXDocument.Entry) throws -> String {
        let written = try write(KDBXDocument(root: .init(entries: [value])))
        return String(written.dropFirst("<KeePassFile><Meta></Meta><Root><Entry>".count)
            .dropLast("</Entry></Root></KeePassFile>".count))
    }

    private func groupXML(_ value: KDBXDocument.Group) throws -> String {
        let written = try write(KDBXDocument(root: .init(groups: [value])))
        return String(written.dropFirst("<KeePassFile><Meta></Meta><Root>".count).dropLast("</Root></KeePassFile>".count))
    }
}
