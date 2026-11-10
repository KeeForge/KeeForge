import Foundation
import KDBXKit
import XCTest
@testable import KDBXXML

final class ReaderTests: XCTestCase {
    // MARK: - Errors

    func test_malformedXML_reportsPosition() {
        XCTAssertThrowsError(try read("<KeePassFile>\n<Root></Meta></KeePassFile>")) { error in
            guard case .malformedXML(let line, let column) = error as? KDBXDocument.ReadError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(line, 2)
            XCTAssertGreaterThan(column, 0)
        }
        XCTAssertThrowsError(try read("")) { error in
            guard case .malformedXML = error as? KDBXDocument.ReadError else { return XCTFail("\(error)") }
        }
    }

    func test_unsupportedInnerStreamIsReportedByKDBXKit() {
        assertThrows(KDBXContainer.ParseError.unsupportedProtectedFieldStream(1)) {
            try KDBXDocument.read(xml: Data("<KeePassFile/>".utf8), innerStreamID: 1, innerStreamKey: Data())
        }
    }

    func test_documentElementMustBeKeePassFile() {
        assertThrows(KDBXDocument.ReadError.unexpectedRootElement("Database")) {
            try read("<Database><Root/></Database>")
        }
    }

    func test_unreadableProtectedValueFailsInsteadOfDesyncingTheStream() {
        let xml = document(root: group(entry("<String><Key>A</Key><Value Protected=\"True\">!!!</Value></String>")))
        assertThrows(KDBXDocument.ReadError.invalidProtectedValue) { try read(xml) }
    }

    // MARK: - Protected values

    func test_protectedValues_unmaskInDocumentOrderAcrossOpaqueFragments() throws {
        let masked = TestStream.masked(["meta-secret", "first", "second", "history"])
        let xml = document(
            root: group(entry("""
            <String><Key>A</Key><Value Protected="True">\(masked[1])</Value></String>\
            <String><Key>B</Key><Value Protected="TRUE">\(masked[2])</Value></String>\
            <History>\(entry("<String><Key>A</Key><Value Protected=\"true\">\(masked[3])</Value></String>"))</History>
            """)),
            meta: "<Vendor><Value Protected=\"True\" Note=\"x\">\(masked[0])</Value></Vendor>"
        )
        let parsed = try read(xml)
        let readEntry = try XCTUnwrap(parsed.root.groups.first?.entries.first)
        XCTAssertEqual(readEntry.strings, [
            .init(key: "A", value: "first", isProtected: true),
            .init(key: "B", value: "second", isProtected: true),
        ])
        XCTAssertEqual(readEntry.history.first?.strings.first?.value, "history")
        XCTAssertEqual(parsed.meta.unknownXML.nodes.first?.xml,
                       #"<Vendor><Value Note="x" Protected="True">meta-secret</Value></Vendor>"#)
    }

    func test_protectedBase64WrappedOverLinesKeepsLaterValuesInStep() throws {
        let masked = TestStream.masked(["first-secret", "second-secret"])
        let wrapped = masked[0].prefix(4) + "\n  " + masked[0].dropFirst(4)
        let xml = document(root: group(entry("""
        <String><Key>A</Key><Value Protected="True">\(wrapped)</Value></String>\
        <String><Key>B</Key><Value Protected="True">\(masked[1])</Value></String>
        """)))
        let strings = try XCTUnwrap(read(xml).root.groups.first?.entries.first?.strings)
        XCTAssertEqual(strings.map(\.value), ["first-secret", "second-secret"])
    }

    func test_protectedValueThatIsNotUTF8ReadsWithReplacementCharacters() throws {
        var stream = TestStream.make()
        let masked = stream.apply(Data([0x61, 0xFF, 0x62])).base64EncodedString()
        let xml = document(root: group(entry("<String><Key>A</Key><Value Protected=\"True\">\(masked)</Value></String>")))
        XCTAssertEqual(try read(xml).root.groups.first?.entries.first?.strings.first?.value, "a\u{FFFD}b")
    }

    func test_emptyProtectedValueConsumesNoKeystream() throws {
        let masked = TestStream.masked(["after"])
        let xml = document(root: group(entry("""
        <String><Key>A</Key><Value Protected="True"/></String>\
        <String><Key>B</Key><Value Protected="True">\(masked[0])</Value></String>
        """)))
        XCTAssertEqual(try read(xml).root.groups.first?.entries.first?.strings.map(\.value), ["", "after"])
    }

    func test_unprotectedStreamPassesValuesThrough() throws {
        let xml = document(root: group(entry("<String><Key>A</Key><Value Protected=\"True\">cGxhaW4=</Value></String>")))
        let parsed = try KDBXDocument.read(xml: Data(xml.utf8), innerStreamID: 0, innerStreamKey: Data())
        XCTAssertEqual(parsed.root.groups.first?.entries.first?.strings.first?.value, "plain")
    }

    // MARK: - Entries

    func test_entry_readsTypedChildrenAndDefaults() throws {
        let xml = document(root: group(entry("""
        <IconID>12</IconID><Tags> a, b ;;c </Tags>\
        <String><Key> Spaced </Key><Value>  kept  </Value></String>\
        <String><Key></Key><Value>no key</Value></String><String><Value>no key either</Value></String>\
        <String><Key>A</Key></String><String><Key>A</Key><Value>again</Value><Extra/></String>
        """)))
        let parsed = try XCTUnwrap(read(xml).root.groups.first?.entries.first)
        XCTAssertEqual(parsed.uuid, TestID.entry)
        XCTAssertEqual(parsed.iconID, 12)
        XCTAssertEqual(parsed.tags, ["a", "b", "c"])
        XCTAssertEqual(parsed.strings.map(\.key), [" Spaced ", "", "", "A", "A"])
        XCTAssertEqual(parsed.strings.map(\.value), ["  kept  ", "no key", "no key either", "", "again"])
        XCTAssertTrue(parsed.unknownXML.isEmpty)
    }

    func test_entry_missingUnreadableOrZeroUUIDGetsARandomOne() throws {
        let zero = UUID.kdbxNone.kdbxBase64String
        let xml = document(root: group("""
        <Entry></Entry><Entry><UUID>bad</UUID><IconID>x</IconID></Entry><Entry><UUID>\(zero)</UUID></Entry>
        """))
        let entries = try XCTUnwrap(read(xml).root.groups.first?.entries)
        XCTAssertEqual(Set(entries.map(\.uuid)).count, 3)
        XCTAssertFalse(entries.contains { $0.uuid == .kdbxNone })
        XCTAssertEqual(entries.map(\.iconID), [0, 0, 0])
        XCTAssertEqual(entries.map(\.tags), [nil, nil, nil])
    }

    func test_entry_attachmentPositionsSkipOtherAttachments() throws {
        let xml = document(root: group(entry("""
        <Binary><Key>first</Key><Value Ref="0"/></Binary><IconID>0</IconID>\
        <Binary><Key>second</Key><Value Ref="1"/></Binary><Binary><Key>third</Key><Value Ref="2"/></Binary>\
        <Vendor/><Binary><Key>bad</Key><Value Ref="x"/></Binary><Binary><Key>none</Key><Value/></Binary>\
        <Binary><Key>sticky</Key><Value Ref="x"/><Value Ref="3"/></Binary><Binary><Extra/><Key>k</Key><Value Ref="4"/></Binary>
        """)))
        let parsed = try XCTUnwrap(read(xml).root.groups.first?.entries.first)
        XCTAssertEqual(parsed.binaries, [
            .init(key: "first", ref: 0, insertionIndex: 1),
            .init(key: "second", ref: 1, insertionIndex: 2),
            .init(key: "third", ref: 2, insertionIndex: 2),
            .init(key: "k", ref: 4, insertionIndex: 2),
        ])
        // UUID, first, IconID, second, third are typed: 5 before <Vendor>.
        XCTAssertEqual(parsed.unknownXML.nodes.map(\.insertionIndex), [5, 5, 5, 5])
        XCTAssertEqual(parsed.unknownXML.nodes.map(\.elementName), ["Vendor", "Binary", "Binary", "Binary"])
    }

    func test_entry_historyKeepsVersionsAndPositionsItsFragments() throws {
        let xml = document(root: group(entry("""
        <History><Note/>\(entry("<IconID>1</IconID>"))<Note>between</Note>\(entry("<IconID>2</IconID>"))<Note/></History>
        """)))
        let parsed = try XCTUnwrap(read(xml).root.groups.first?.entries.first)
        XCTAssertEqual(parsed.history.map(\.iconID), [1, 2])
        XCTAssertEqual(parsed.unknownXML.nodes, [
            .init(path: ["History"], insertionIndex: 0, xml: "<Note></Note>"),
            .init(path: ["History"], insertionIndex: 1, xml: "<Note>between</Note>"),
            .init(path: ["History"], insertionIndex: 2, xml: "<Note></Note>"),
        ])
    }

    func test_times_typedOnlyWhenTheyParse() throws {
        let created = Date(unix: 1_600_000_000)
        let xml = document(root: group(entry("""
        <Times><CreationTime>\(created.kdbxBase64String)</CreationTime><LastModificationTime>soon</LastModificationTime>\
        <ExpiryTime>\(created.kdbxBase64String)</ExpiryTime><Expires>true</Expires>\
        <LocationChanged> 2020-09-13T12:26:40Z </LocationChanged></Times>
        """)))
        let parsed = try XCTUnwrap(read(xml).root.groups.first?.entries.first)
        XCTAssertEqual(parsed.times, .init(creationTime: created, lastModificationTime: nil, locationChanged: created))
        XCTAssertEqual(parsed.unknownXML.nodes, [
            .init(path: ["Times"], insertionIndex: 1, xml: "<LastModificationTime>soon</LastModificationTime>"),
            .init(path: ["Times"], insertionIndex: 1, xml: "<ExpiryTime>\(created.kdbxBase64String)</ExpiryTime>"),
            .init(path: ["Times"], insertionIndex: 1, xml: "<Expires>true</Expires>"),
        ])
        XCTAssertEqual(parsed.expiryTime, created)
        XCTAssertTrue(parsed.expires)
    }

    /// KeePassXC writes a KDBX 4.1 `<CustomData>` item timestamp after
    /// `<Times>`; it once replaced the entry's own modification time.
    func test_customDataItemTimestampsDoNotReplaceEntryOrGroupTimes() throws {
        let own = Date(unix: 1_600_000_000)
        let item = Date(unix: 1_700_000_000).kdbxBase64String
        let customData = "<CustomData><Item><Key>K</Key><Value>V</Value><LastModificationTime>\(item)</LastModificationTime></Item></CustomData>"
        let times = "<Times><LastModificationTime>\(own.kdbxBase64String)</LastModificationTime></Times>"
        let parsed = try read(document(root: group(times + entry(times + customData) + customData)))
        let readGroup = try XCTUnwrap(parsed.root.groups.first)
        XCTAssertEqual(readGroup.times.lastModificationTime, own)
        XCTAssertEqual(readGroup.entries.first?.times.lastModificationTime, own)
    }

    func test_elementsOutsideTheirContainerStayOpaque() throws {
        let xml = document(root: group(entry("""
        <AutoType><Association><Window>W</Window></Association><UUID>\(TestID.other.kdbxBase64String)</UUID></AutoType>\
        <Vendor><Entry><UUID>\(TestID.other.kdbxBase64String)</UUID></Entry><Group/><Times/><String/></Vendor>
        """) + "<Vendor><Name>not the group name</Name><IconID>3</IconID></Vendor>"))
        let parsed = try XCTUnwrap(read(xml).root.groups.first)
        XCTAssertEqual(parsed.name, "G")
        XCTAssertEqual(parsed.iconID, 48)
        XCTAssertEqual(parsed.groups.count, 0)
        let readEntry = try XCTUnwrap(parsed.entries.first)
        XCTAssertEqual(readEntry.uuid, TestID.entry)
        XCTAssertEqual(readEntry.unknownXML.nodes.map(\.elementName), ["AutoType", "Vendor"])
        XCTAssertEqual(parsed.unknownXML.nodes.map(\.elementName), ["Vendor"])
    }

    // MARK: - Groups

    func test_group_readsTypedChildren() throws {
        let created = Date(unix: 1_500_000_000)
        let xml = document(root: """
        <Group><UUID>\(TestID.group.kdbxBase64String)</UUID><Name> Spaced </Name><Notes>\n note \n</Notes>\
        <IconID>7</IconID><IsExpanded>FALSE</IsExpanded>\
        <Times><CreationTime>\(created.kdbxBase64String)</CreationTime></Times>\
        <EnableSearching>False</EnableSearching><Tags>x;y</Tags>\
        <Group><Name>child</Name><IsExpanded>yes</IsExpanded><EnableSearching>maybe</EnableSearching></Group></Group>
        """)
        let parsed = try XCTUnwrap(read(xml).root.groups.first)
        XCTAssertEqual(parsed.uuid, TestID.group)
        XCTAssertEqual(parsed.name, " Spaced ")
        XCTAssertEqual(parsed.notes, "\n note \n")
        XCTAssertEqual(parsed.iconID, 7)
        XCTAssertFalse(parsed.isExpanded)
        XCTAssertEqual(parsed.times.creationTime, created)
        XCTAssertEqual(parsed.enableSearching, .disabled)
        XCTAssertEqual(parsed.tags, ["x", "y"])
        let unreadableIcon = try read(document(root: group("<IconID>folder</IconID>")))
        XCTAssertEqual(unreadableIcon.root.groups.first?.iconID, 0)
        let child = try XCTUnwrap(parsed.groups.first)
        XCTAssertTrue(child.isExpanded)
        XCTAssertNil(child.enableSearching)
        XCTAssertNil(child.notes)
        XCTAssertNil(child.tags)
        XCTAssertEqual(child.iconID, 48)
        XCTAssertEqual(child.unknownXML.nodes, [.init(insertionIndex: 2, xml: "<EnableSearching>maybe</EnableSearching>")])
    }

    func test_group_enableSearchingReadsEveryKeePassSpelling() throws {
        for (text, expected) in [("null", KDBXDocument.InheritableBool.inherit), (" TRUE ", .enabled), ("false", .disabled)] {
            let parsed = try read(document(root: group("<EnableSearching>\(text)</EnableSearching>")))
            XCTAssertEqual(parsed.root.groups.first?.enableSearching, expected, text)
        }
    }

    // MARK: - Meta and root

    func test_meta_typedSettingsOnlyWhenTheyParse() throws {
        let zero = UUID.kdbxNone.kdbxBase64String
        let parsed = try read(document(root: "", meta: """
        <Generator>X</Generator><RecycleBinUUID>\(zero)</RecycleBinUUID><MaintenanceHistoryDays>soon</MaintenanceHistoryDays>\
        <HistoryMaxItems> 5 </HistoryMaxItems><HistoryMaxSize>99999999999</HistoryMaxSize><Tail/>
        """))
        XCTAssertEqual(parsed.meta.recycleBin, .unset)
        XCTAssertNil(parsed.meta.maintenanceHistoryDays)
        XCTAssertEqual(parsed.meta.historyMaxItems, 5)
        XCTAssertEqual(parsed.meta.historyMaxSize, 99_999_999_999)
        XCTAssertEqual(parsed.meta.unknownXML.nodes, [
            .init(insertionIndex: 0, xml: "<Generator>X</Generator>"),
            .init(insertionIndex: 1, xml: "<MaintenanceHistoryDays>soon</MaintenanceHistoryDays>"),
            .init(insertionIndex: 3, xml: "<Tail></Tail>"),
        ])
        let bad = try read(document(root: "", meta: "<RecycleBinUUID>short</RecycleBinUUID><HistoryMaxItems>x</HistoryMaxItems><HistoryMaxSize>y</HistoryMaxSize>"))
        XCTAssertNil(bad.meta.recycleBin)
        XCTAssertEqual(bad.meta.unknownXML.nodes.count, 3)
    }

    func test_recycleBin_readsAbsentZeroAndGroup() throws {
        XCTAssertNil(try read(document(root: "")).meta.recycleBin)
        let zero = try read(document(root: "", meta: "<RecycleBinUUID>AAAAAAAAAAAAAAAAAAAAAA==</RecycleBinUUID>"))
        XCTAssertEqual(zero.meta.recycleBin, .unset)
        let set = try read(document(root: "", meta: "<RecycleBinUUID> AQIDBAUGBwgJCgsMDQ4PEA== </RecycleBinUUID>"))
        XCTAssertEqual(set.meta.recycleBin, .group(try XCTUnwrap(UUID(uuidString: "01020304-0506-0708-090A-0B0C0D0E0F10"))))
    }

    func test_meta_lastOneWins() throws {
        let parsed = try read("<KeePassFile><Meta><HistoryMaxItems>1</HistoryMaxItems></Meta><Meta><HistoryMaxItems>2</HistoryMaxItems></Meta><Root/></KeePassFile>")
        XCTAssertEqual(parsed.meta.historyMaxItems, 2)
    }

    func test_root_readsEntriesGroupsTombstonesAndFragments() throws {
        let deleted = Date(unix: 1_650_000_000)
        let parsed = try read(document(root: """
        <Lead/>\(entry(""))<Group><Name>A</Name></Group><Mid/>\
        <DeletedObjects><DeletedObject><UUID>\(TestID.other.kdbxBase64String)</UUID><DeletionTime>\(deleted.kdbxBase64String)</DeletionTime><Extra/></DeletedObject>\
        <DeletedObject><UUID>\(UUID.kdbxNone.kdbxBase64String)</UUID><DeletionTime>\(deleted.kdbxBase64String)</DeletionTime></DeletedObject>\
        <DeletedObject><UUID>\(TestID.other.kdbxBase64String)</UUID></DeletedObject><Stray/></DeletedObjects><Tail/>
        """) + "")
        XCTAssertEqual(parsed.root.entries.map(\.uuid), [TestID.entry])
        XCTAssertEqual(parsed.root.groups.map(\.name), ["A"])
        XCTAssertEqual(parsed.root.deletedObjects, [.init(uuid: TestID.other, deletionTime: deleted)])
        XCTAssertEqual(parsed.root.unknownXML.nodes, [
            .init(insertionIndex: 0, xml: "<Lead></Lead>"),
            .init(insertionIndex: 2, xml: "<Mid></Mid>"),
            .init(insertionIndex: 3, xml: "<Tail></Tail>"),
        ])
    }

    func test_document_keepsUnknownChildrenInTheirSlotAroundMetaAndRoot() throws {
        let masked = TestStream.masked(["before", "meta", "between", "entry", "after"])
        let parsed = try read("""
        <KeePassFile><Lead><Value Protected="True">\(masked[0])</Value></Lead>\
        <Meta><V><Value Protected="True">\(masked[1])</Value></V></Meta>\
        <Mid><Value Protected="True">\(masked[2])</Value></Mid>\
        <Root>\(entry("<String><Key>P</Key><Value Protected=\"True\">\(masked[3])</Value></String>"))</Root>\
        <Tail><Value Protected="True">\(masked[4])</Value></Tail><Tail2/></KeePassFile>
        """)
        XCTAssertEqual(parsed.unknownXML.nodes, [
            .init(insertionIndex: 0, xml: #"<Lead><Value Protected="True">before</Value></Lead>"#),
            .init(insertionIndex: 1, xml: #"<Mid><Value Protected="True">between</Value></Mid>"#),
            .init(insertionIndex: 2, xml: #"<Tail><Value Protected="True">after</Value></Tail>"#),
            .init(insertionIndex: 2, xml: "<Tail2></Tail2>"),
        ])
        XCTAssertEqual(parsed.meta.unknownXML.nodes.first?.xml, #"<V><Value Protected="True">meta</Value></V>"#)
        XCTAssertEqual(parsed.root.entries.first?.strings.first?.value, "entry")
    }

    /// The writer always emits `<Meta>` then `<Root>`, so a fragment's slot is
    /// where it sat relative to each, whether the source had one, both, or
    /// them reversed.
    func test_document_slotsFollowMetaAndRootWhateverTheSourceOrder() throws {
        let slots = { (xml: String) in try read(xml).unknownXML.nodes.map(\.insertionIndex) }
        XCTAssertEqual(try slots("<KeePassFile><A/><Root/><B/></KeePassFile>"), [0, 2])
        XCTAssertEqual(try slots("<KeePassFile><Root/><A/><Meta/><B/></KeePassFile>"), [2, 2])
        XCTAssertEqual(try slots("<KeePassFile><Meta/><A/><Meta/><B/><Root/></KeePassFile>"), [1, 1])
    }

    // MARK: - Canonical fragments

    func test_fragmentsAreRenderedCanonically() throws {
        let parsed = try read(document(root: "", meta: """
        <V b='2' a="1&amp;&lt;&quot;">t &amp; &lt;x&gt; &#xD;<!-- dropped --><Empty/><![CDATA[<cdata>]]></V>
        """))
        // Comments are dropped; CDATA becomes escaped text.
        XCTAssertEqual(parsed.meta.unknownXML.nodes.first?.xml,
                       #"<V a="1&amp;&lt;&quot;" b="2">t &amp; &lt;x&gt; &#xD;<Empty></Empty>&lt;cdata&gt;</V>"#)
    }
}
