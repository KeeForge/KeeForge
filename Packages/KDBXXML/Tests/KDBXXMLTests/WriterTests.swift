import Foundation
import KDBXKit
import XCTest
@testable import KDBXXML

final class WriterTests: XCTestCase {
    private let uuid = TestID.entry.kdbxBase64String
    private let groupUUID = TestID.group.kdbxBase64String

    func test_emptyDocument_writesTheSkeletonWithProlog() throws {
        let data = try KDBXDocument().serialized(innerStream: .chaCha20, innerStreamKey: TestStream.key)
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(try write(KDBXDocument()), "<KeePassFile><Meta></Meta><Root></Root></KeePassFile>")
    }

    func test_meta_writesSettingsInKeePassOrderAroundFragments() throws {
        var meta = KDBXDocument.Meta(recycleBin: .unset, maintenanceHistoryDays: 30, historyMaxItems: 5, historyMaxSize: 1024)
        meta.unknownXML = OpaqueXMLNodes(nodes: [
            .init(insertionIndex: 0, xml: "<A></A>"),
            .init(insertionIndex: 2, xml: "<B></B>"),
            .init(insertionIndex: 9, xml: "<Z></Z>"),
        ])
        XCTAssertEqual(try write(KDBXDocument(meta: meta)), """
        <KeePassFile><Meta><A></A><RecycleBinUUID>AAAAAAAAAAAAAAAAAAAAAA==</RecycleBinUUID>\
        <MaintenanceHistoryDays>30</MaintenanceHistoryDays><B></B><HistoryMaxItems>5</HistoryMaxItems>\
        <HistoryMaxSize>1024</HistoryMaxSize><Z></Z></Meta><Root></Root></KeePassFile>
        """)
    }

    func test_recycleBin_writesNothingZeroOrTheGroup() throws {
        XCTAssertEqual(try write(KDBXDocument(meta: .init(recycleBin: nil))), "<KeePassFile><Meta></Meta><Root></Root></KeePassFile>")
        let group = try XCTUnwrap(UUID(uuidString: "01020304-0506-0708-090A-0B0C0D0E0F10"))
        for (value, text) in [(KDBXDocument.RecycleBin.unset, "AAAAAAAAAAAAAAAAAAAAAA=="), (.group(group), "AQIDBAUGBwgJCgsMDQ4PEA==")] {
            XCTAssertEqual(
                try write(KDBXDocument(meta: .init(recycleBin: value))),
                "<KeePassFile><Meta><RecycleBinUUID>\(text)</RecycleBinUUID></Meta><Root></Root></KeePassFile>"
            )
        }
    }

    func test_group_writesKeePassChildOrder() throws {
        let created = Date(unix: 1_600_000_000)
        let child = KDBXDocument.Group(uuid: TestID.other, name: "child")
        let written = try write(KDBXDocument(root: .init(groups: [
            KDBXDocument.Group(
                uuid: TestID.group, name: "a<b>&\r", notes: "n", iconID: 3, isExpanded: false,
                times: .init(creationTime: created), enableSearching: .inherit, tags: ["x", "y"],
                entries: [KDBXDocument.Entry(uuid: TestID.entry)], groups: [child]
            ),
        ])))
        XCTAssertEqual(written, """
        <KeePassFile><Meta></Meta><Root><Group><UUID>\(groupUUID)</UUID><Name>a&lt;b&gt;&amp;&#xD;</Name>\
        <Notes>n</Notes><IconID>3</IconID><IsExpanded>False</IsExpanded>\
        <Times><CreationTime>\(created.kdbxBase64String)</CreationTime></Times><EnableSearching>null</EnableSearching>\
        <Tags>x,y</Tags><Entry><UUID>\(uuid)</UUID><IconID>0</IconID></Entry>\
        <Group><UUID>\(TestID.other.kdbxBase64String)</UUID><Name>child</Name><IconID>48</IconID>\
        <IsExpanded>True</IsExpanded></Group></Group></Root></KeePassFile>
        """)
    }

    func test_group_absentOptionalElementsAreNotInvented() throws {
        let written = try write(KDBXDocument(root: .init(groups: [KDBXDocument.Group(uuid: TestID.group)])))
        for name in ["Notes", "Times", "EnableSearching", "Tags"] {
            XCTAssertFalse(written.contains("<\(name)>"), name)
        }
        let empty = try write(KDBXDocument(root: .init(groups: [KDBXDocument.Group(uuid: TestID.group, notes: "", tags: [])])))
        XCTAssertTrue(empty.contains("<Notes></Notes>"))
        XCTAssertTrue(empty.contains("<Tags></Tags>"))
    }

    func test_entry_writesFieldsInOrderAndMasksProtectedOnes() throws {
        let masked = TestStream.masked(["s3cret", "history"])
        let value = KDBXDocument.Entry(
            uuid: TestID.entry, iconID: 4, tags: [],
            strings: [.init(key: "Title", value: "t&"), .init(key: "Password", value: "s3cret", isProtected: true)],
            history: [KDBXDocument.Entry(uuid: TestID.entry, strings: [.init(key: "P", value: "history", isProtected: true)])]
        )
        let written = try write(KDBXDocument(root: .init(entries: [value])))
        XCTAssertEqual(written, """
        <KeePassFile><Meta></Meta><Root><Entry><UUID>\(uuid)</UUID><IconID>4</IconID><Tags></Tags>\
        <String><Key>Title</Key><Value>t&amp;</Value></String>\
        <String><Key>Password</Key><Value Protected="True">\(masked[0])</Value></String>\
        <History><Entry><UUID>\(uuid)</UUID><IconID>0</IconID>\
        <String><Key>P</Key><Value Protected="True">\(masked[1])</Value></String></Entry></History>\
        </Entry></Root></KeePassFile>
        """)
    }

    func test_entry_attachmentsReturnToTheirPositions() throws {
        var value = KDBXDocument.Entry(uuid: TestID.entry, strings: [.init(key: "A", value: "a")])
        value.binaries = [
            .init(key: "first", ref: 0, insertionIndex: 0),
            .init(key: "second", ref: 1, insertionIndex: 2),
            .init(key: "third", ref: 2, insertionIndex: 2),
            .init(key: "late", ref: 3, insertionIndex: 9),
        ]
        value.unknownXML = OpaqueXMLNodes(nodes: [
            .init(insertionIndex: 1, xml: "<AfterFirst></AfterFirst>"),
            .init(insertionIndex: 4, xml: "<AfterSecond></AfterSecond>"),
            .init(insertionIndex: 9, xml: "<Tail></Tail>"),
        ])
        let written = try write(KDBXDocument(root: .init(entries: [value])))
        XCTAssertEqual(written, """
        <KeePassFile><Meta></Meta><Root><Entry><Binary><Key>first</Key><Value Ref="0"/></Binary>\
        <AfterFirst></AfterFirst><UUID>\(uuid)</UUID><IconID>0</IconID>\
        <Binary><Key>second</Key><Value Ref="1"/></Binary><AfterSecond></AfterSecond>\
        <Binary><Key>third</Key><Value Ref="2"/></Binary><String><Key>A</Key><Value>a</Value></String>\
        <Binary><Key>late</Key><Value Ref="3"/></Binary><Tail></Tail></Entry></Root></KeePassFile>
        """)
    }

    func test_timesAndHistoryAreWrittenForTheirFragmentsAlone() throws {
        var value = KDBXDocument.Entry(uuid: TestID.entry)
        value.unknownXML = OpaqueXMLNodes(nodes: [
            .init(path: ["Times"], insertionIndex: 0, xml: "<Expires>False</Expires>"),
            .init(path: ["History"], insertionIndex: 0, xml: "<Note></Note>"),
        ])
        XCTAssertEqual(try write(KDBXDocument(root: .init(entries: [value]))), """
        <KeePassFile><Meta></Meta><Root><Entry><UUID>\(uuid)</UUID><IconID>0</IconID>\
        <Times><Expires>False</Expires></Times><History><Note></Note></History></Entry></Root></KeePassFile>
        """)
    }

    func test_times_locationChangedFollowsTheUntypedChildren() throws {
        let date = Date(unix: 1_600_000_000).kdbxBase64String
        let parsed = try read(document(root: group("""
        <Times><LastModificationTime>\(date)</LastModificationTime><CreationTime>\(date)</CreationTime>\
        <LastAccessTime>\(date)</LastAccessTime><ExpiryTime>\(date)</ExpiryTime><Expires>False</Expires>\
        <UsageCount>0</UsageCount><LocationChanged>\(date)</LocationChanged></Times>
        """)))
        let written = try write(parsed)
        XCTAssertTrue(written.contains("""
        <Times><CreationTime>\(date)</CreationTime><LastModificationTime>\(date)</LastModificationTime>\
        <LastAccessTime>\(date)</LastAccessTime><ExpiryTime>\(date)</ExpiryTime><Expires>False</Expires>\
        <UsageCount>0</UsageCount><LocationChanged>\(date)</LocationChanged></Times>
        """), written)
    }

    func test_rootWritesTombstonesAfterGroups() throws {
        let deleted = Date(unix: 1_650_000_000)
        let root = KDBXDocument.Root(
            groups: [KDBXDocument.Group(uuid: TestID.group)],
            deletedObjects: [.init(uuid: TestID.other, deletionTime: deleted)],
            unknownXML: OpaqueXMLNodes(nodes: [.init(insertionIndex: 1, xml: "<Mid></Mid>")])
        )
        XCTAssertEqual(try write(KDBXDocument(root: root)), """
        <KeePassFile><Meta></Meta><Root><Group><UUID>\(groupUUID)</UUID><Name></Name><IconID>48</IconID>\
        <IsExpanded>True</IsExpanded></Group><Mid></Mid><DeletedObjects><DeletedObject>\
        <UUID>\(TestID.other.kdbxBase64String)</UUID><DeletionTime>\(deleted.kdbxBase64String)</DeletionTime>\
        </DeletedObject></DeletedObjects></Root></KeePassFile>
        """)
    }

    // MARK: - A typed child replaces a preserved one

    func test_typedChildReplacesAPreservedElementOfTheSameName() throws {
        let date = Date(unix: 1_600_000_000)
        let parsed = try read(document(
            root: group("<EnableSearching>maybe</EnableSearching>" + entry("<Times><LocationChanged>later</LocationChanged></Times>")),
            meta: "<MaintenanceHistoryDays>soon</MaintenanceHistoryDays>"
        ))
        XCTAssertTrue(try write(parsed).contains("<EnableSearching>maybe</EnableSearching>"), "kept while untyped")

        var edited = parsed
        edited.meta.maintenanceHistoryDays = 7
        edited.root.groups[0].enableSearching = .enabled
        edited.root.groups[0].entries[0].times.locationChanged = date
        let written = try write(edited)
        XCTAssertFalse(written.contains("maybe"))
        XCTAssertFalse(written.contains("soon"))
        XCTAssertFalse(written.contains("later"))
        XCTAssertTrue(written.contains("<EnableSearching>True</EnableSearching>"))
        XCTAssertTrue(written.contains("<MaintenanceHistoryDays>7</MaintenanceHistoryDays>"))
        XCTAssertTrue(written.contains("<LocationChanged>\(date.kdbxBase64String)</LocationChanged>"))
    }

    func test_repeatableElementsAreNeverReplaced() throws {
        let parsed = try read(document(root: group(entry("""
        <Binary><Key>bad</Key><Value Ref="x"/></Binary><Binary><Key>good</Key><Value Ref="0"/></Binary>
        """))))
        let written = try write(parsed)
        XCTAssertTrue(written.contains(#"<Binary><Key>bad</Key><Value Ref="x"></Value></Binary>"#))
        XCTAssertTrue(written.contains(#"<Binary><Key>good</Key><Value Ref="0"/></Binary>"#))
    }

    // MARK: - Protected values in fragments

    /// Masking once ran in reverse within a fragment, so a fragment with two
    /// protected values read back garbled.
    func test_protectedValuesInOneFragmentAreMaskedInDocumentOrder() throws {
        let fragment = #"<Vendor><Value Protected="True">first &amp; &lt;&#xD;</Value><Value Protected="true">second</Value></Vendor>"#
        let meta = KDBXDocument.Meta(unknownXML: OpaqueXMLNodes(nodes: [.init(insertionIndex: 0, xml: fragment)]))
        let written = try write(KDBXDocument(meta: meta))
        let masked = TestStream.masked(["first & <\r", "second"])
        XCTAssertTrue(written.contains(#"<Value Protected="True">\#(masked[0])</Value><Value Protected="true">\#(masked[1])</Value>"#), written)
        XCTAssertEqual(try read(written).meta.unknownXML.nodes.first?.xml, fragment)
    }

    func test_protectedValuesInterleaveWithTypedFieldsInDocumentOrder() throws {
        var value = KDBXDocument.Entry(uuid: TestID.entry, strings: [
            .init(key: "A", value: "one", isProtected: true),
            .init(key: "B", value: "three", isProtected: true),
        ])
        value.unknownXML = OpaqueXMLNodes(nodes: [
            .init(insertionIndex: 3, xml: #"<X><Value Protected="True">two</Value></X>"#),
            .init(insertionIndex: 9, xml: #"<Y><Value Protected="True">four</Value></Y>"#),
        ])
        let written = try write(KDBXDocument(root: .init(entries: [value])))
        let masked = TestStream.masked(["one", "two", "three", "four"])
        let positions = masked.compactMap { written.range(of: $0)?.lowerBound }
        XCTAssertEqual(positions.count, 4)
        XCTAssertEqual(positions, positions.sorted())
        var expected = value
        expected.unknownXML.nodes[1] = .init(insertionIndex: 4, xml: #"<Y><Value Protected="True">four</Value></Y>"#)
        XCTAssertEqual(try read(written).root.entries.first, expected, "trailing positions renumber")
    }

    func test_protectedValuesInFragmentsBeforeAnEntryAreMaskedFirst() throws {
        let root = KDBXDocument.Root(
            entries: [KDBXDocument.Entry(uuid: TestID.entry, strings: [.init(key: "P", value: "second", isProtected: true)])],
            unknownXML: OpaqueXMLNodes(nodes: [.init(insertionIndex: 0, xml: #"<X><Value Protected="True">first</Value></X>"#)])
        )
        let reread = try read(write(KDBXDocument(root: root)))
        XCTAssertEqual(reread.root, root)
    }

    func test_documentFragmentsSurroundMetaAndRootWithProtectedValuesInOrder() throws {
        let document = KDBXDocument(
            meta: .init(unknownXML: OpaqueXMLNodes(nodes: [.init(insertionIndex: 0, xml: #"<V><Value Protected="True">meta</Value></V>"#)])),
            root: .init(entries: [KDBXDocument.Entry(uuid: TestID.entry, strings: [.init(key: "P", value: "entry", isProtected: true)])]),
            unknownXML: OpaqueXMLNodes(nodes: [
                .init(insertionIndex: 2, xml: #"<Tail><Value Protected="True">after</Value></Tail>"#),
                .init(insertionIndex: 0, xml: #"<Lead><Value Protected="True">before</Value></Lead>"#),
                .init(insertionIndex: 1, xml: #"<Mid><Value Protected="True">between</Value></Mid>"#),
                .init(insertionIndex: 0, xml: "<Meta></Meta>"),
                .init(insertionIndex: 2, xml: "<Root></Root>"),
            ])
        )
        let masked = TestStream.masked(["before", "meta", "between", "entry", "after"])
        XCTAssertEqual(try write(document), """
        <KeePassFile><Lead><Value Protected="True">\(masked[0])</Value></Lead>\
        <Meta><V><Value Protected="True">\(masked[1])</Value></V></Meta>\
        <Mid><Value Protected="True">\(masked[2])</Value></Mid>\
        <Root><Entry><UUID>\(uuid)</UUID><IconID>0</IconID>\
        <String><Key>P</Key><Value Protected="True">\(masked[3])</Value></String></Entry></Root>\
        <Tail><Value Protected="True">\(masked[4])</Value></Tail></KeePassFile>
        """, "a typed Meta or Root replaces a fragment of that name")
    }

    func test_valuesThatAreNotProtectedAreCopiedVerbatim() throws {
        let fragments = [
            #"<Value Protected="False">plain</Value>"#,
            #"<Value Note="Protected=&quot;True&quot;">plain</Value>"#,
            #"<ValueX Protected="True">plain</ValueX>"#,
            #"<Value ProtectedInMemory="True">plain</Value>"#,
            #"<Value Protected="True"/><Value>after</Value>"#,
            #"<Value Protected="True">no closing tag"#,
            "plain text with <Value",
        ]
        for fragment in fragments {
            let meta = KDBXDocument.Meta(unknownXML: OpaqueXMLNodes(nodes: [.init(insertionIndex: 0, xml: fragment)]))
            XCTAssertTrue(try write(KDBXDocument(meta: meta)).contains(fragment), fragment)
        }
    }

    func test_fragmentsThatAreNotElementsAreNeverReplaced() throws {
        let group = KDBXDocument.Group(uuid: TestID.group, unknownXML: OpaqueXMLNodes(nodes: [.init(insertionIndex: 0, xml: "loose text")]))
        XCTAssertTrue(try write(KDBXDocument(root: .init(groups: [group]))).contains("<Group>loose text<UUID>"))
    }

    // MARK: - Validation

    func test_validate_acceptsEveryXMLCharacterAndRejectsTheRest() throws {
        XCTAssertNoThrow(try KDBXDocument.validate(text: "tab\t lf\n cr\r \u{20} \u{D7FF} \u{E000} \u{FFFD} \u{10000} \u{10FFFF}"))
        for value: UInt32 in [0x00, 0x08, 0x0B, 0x0C, 0x0E, 0x1F, 0xFFFE, 0xFFFF] {
            let scalar = try XCTUnwrap(Unicode.Scalar(value))
            assertThrows(KDBXDocument.TextError.invalidXMLCharacter(scalar)) {
                try KDBXDocument.validate(text: "ok\(Character(scalar))")
            }
        }
    }

    func test_serializeNamesWhereEachInvalidCharacterIs() {
        typealias Location = KDBXDocument.WriteError.Location
        let nul = "a\u{0}b"
        func nodes(_ xml: String, path: [String] = []) -> OpaqueXMLNodes {
            OpaqueXMLNodes(nodes: [.init(path: path, insertionIndex: 0, xml: xml)])
        }
        func inGroup(_ group: KDBXDocument.Group) -> KDBXDocument {
            KDBXDocument(root: .init(groups: [KDBXDocument.Group(groups: [group])]))
        }
        func inEntry(_ entry: KDBXDocument.Entry) -> KDBXDocument {
            KDBXDocument(root: .init(groups: [KDBXDocument.Group(entries: [entry])]))
        }
        let group = TestID.group
        let entry = TestID.entry
        let cases: [(KDBXDocument, Location)] = [
            (KDBXDocument(unknownXML: nodes("<Lead>\(nul)</Lead>")), Location(owner: .document, part: .element("Lead"))),
            (KDBXDocument(meta: .init(unknownXML: nodes("<V>\(nul)</V>"))), Location(owner: .meta, part: .element("V"))),
            (KDBXDocument(root: .init(unknownXML: nodes(nul))), Location(owner: .root, part: .element(nil))),
            (inGroup(.init(uuid: group, name: nul)), Location(owner: .group(group), part: .element("Name"))),
            (inGroup(.init(uuid: group, notes: nul)), Location(owner: .group(group), part: .element("Notes"))),
            (inGroup(.init(uuid: group, tags: ["ok", nul])), Location(owner: .group(group), part: .element("Tags"))),
            (inGroup(.init(uuid: group, unknownXML: nodes("<ExpiryTime>\(nul)</ExpiryTime>", path: ["Times"]))),
             Location(owner: .group(group), part: .element("ExpiryTime"))),
            (KDBXDocument(root: .init(entries: [.init(uuid: entry, tags: [nul])])),
             Location(owner: .entry(entry), part: .element("Tags"))),
            (inEntry(.init(uuid: entry, strings: [.init(key: nul, value: "")])), Location(owner: .entry(entry), part: .field(key: nul))),
            (inEntry(.init(uuid: entry, strings: [.init(key: "Notes", value: nul)])), Location(owner: .entry(entry), part: .field(key: "Notes"))),
            (inEntry(.init(uuid: entry, binaries: [.init(key: nul, ref: 0)])), Location(owner: .entry(entry), part: .attachment(key: nul))),
            (inEntry(.init(uuid: entry, unknownXML: nodes("<CustomData>\(nul)</CustomData>"))),
             Location(owner: .entry(entry), part: .element("CustomData"))),
            (inEntry(.init(uuid: entry, history: [.init(uuid: entry, strings: [.init(key: "Title", value: nul)])])),
             Location(owner: .historyEntry(entry), part: .field(key: "Title"))),
        ]
        for (document, location) in cases {
            assertThrows(KDBXDocument.WriteError.invalidXMLCharacter("\u{0}", at: location)) { try write(document) }
        }
    }

    func test_protectedFragmentValuesMayHoldAnyScalar() throws {
        let fragment = "<Item><Value Protected=\"True\">a\u{0}b</Value></Item>"
        let meta = KDBXDocument.Meta(unknownXML: OpaqueXMLNodes(nodes: [.init(insertionIndex: 0, xml: fragment)]))
        let written = try write(KDBXDocument(meta: meta))
        XCTAssertEqual(try read(written).meta.unknownXML.nodes.first?.xml, fragment)
    }

    func test_protectedValuesMayHoldAnyScalar() throws {
        let value = KDBXDocument.Entry(uuid: TestID.entry, strings: [.init(key: "P", value: "a\u{0}\u{FFFE}b", isProtected: true)])
        let written = try write(KDBXDocument(root: .init(entries: [value])))
        XCTAssertEqual(try read(written).root.entries.first?.strings.first?.value, "a\u{0}\u{FFFE}b")
    }
}
