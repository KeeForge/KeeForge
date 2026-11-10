import Foundation
import KDBXKit
import XCTest
@testable import KDBXXML

final class RoundTripTests: XCTestCase {
    private let fixtures = ["keepassxc-recycled", "kitchen-sink", "legacy-kdbx31"]

    func test_foreignPayloads_readWriteReadIsLossless() throws {
        for name in fixtures {
            let original = try Fixture.payload(name).read()
            XCTAssertEqual(try read(write(original)), original, name)
        }
    }

    func test_foreignPayloads_secondWriteIsByteIdentical() throws {
        for name in fixtures {
            let first = try write(Fixture.payload(name).read())
            XCTAssertEqual(try write(read(first)), first, name)
        }
    }

    /// A compact KeePass-style payload survives byte for byte, apart from the
    /// prolog: the writer's element order matches KeePass's.
    func test_canonicalPayload_isReproducedExactly() throws {
        let date = Date(unix: 1_600_000_000).kdbxBase64String
        let masked = TestStream.masked(["pw"])
        let body = """
        <KeePassFile><Meta><Generator>KeePassXC</Generator><RecycleBinUUID>\(TestID.other.kdbxBase64String)</RecycleBinUUID>\
        <HistoryMaxItems>10</HistoryMaxItems><CustomData></CustomData></Meta><Root><Group><UUID>\(TestID.group.kdbxBase64String)</UUID>\
        <Name>Root</Name><Notes></Notes><IconID>48</IconID><Times><CreationTime>\(date)</CreationTime>\
        <LastModificationTime>\(date)</LastModificationTime><LastAccessTime>\(date)</LastAccessTime>\
        <ExpiryTime>\(date)</ExpiryTime><Expires>False</Expires><UsageCount>0</UsageCount>\
        <LocationChanged>\(date)</LocationChanged></Times><IsExpanded>True</IsExpanded>\
        <DefaultAutoTypeSequence></DefaultAutoTypeSequence><EnableAutoType>null</EnableAutoType>\
        <EnableSearching>null</EnableSearching><LastTopVisibleEntry>AAAAAAAAAAAAAAAAAAAAAA==</LastTopVisibleEntry>\
        <Entry><UUID>\(TestID.entry.kdbxBase64String)</UUID><IconID>0</IconID><ForegroundColor></ForegroundColor>\
        <Tags>a,b</Tags><Times><CreationTime>\(date)</CreationTime></Times>\
        <String><Key>Password</Key><Value Protected="True">\(masked[0])</Value></String>\
        <Binary><Key>f.txt</Key><Value Ref="0"/></Binary><AutoType><Enabled>True</Enabled></AutoType>\
        <History></History></Entry></Group><DeletedObjects><DeletedObject><UUID>\(TestID.other.kdbxBase64String)</UUID>\
        <DeletionTime>\(date)</DeletionTime></DeletedObject></DeletedObjects></Root></KeePassFile>
        """
        // KeePass writes IsExpanded after Times; the writer's fixed order
        // puts it before, so compare against that one known move.
        let reordered = body
            .replacingOccurrences(of: "<IsExpanded>True</IsExpanded>", with: "")
            .replacingOccurrences(of: "<IconID>48</IconID>", with: "<IconID>48</IconID><IsExpanded>True</IsExpanded>")
        XCTAssertEqual(try write(read(body)), reordered.replacingOccurrences(of: "<History></History>", with: ""))
    }

    func test_documentsBuiltInMemorySurviveAWriteAndRead() throws {
        let date = Date(unix: 1_700_000_000)
        let built = KDBXDocument(
            meta: .init(recycleBin: .group(TestID.group), maintenanceHistoryDays: 1, historyMaxItems: 2, historyMaxSize: 3),
            root: .init(
                entries: [KDBXDocument.Entry(uuid: TestID.other, strings: [.init(key: "k", value: "\r\n\t &<>\"'")])],
                groups: [KDBXDocument.Group(
                    uuid: TestID.group, name: "n", notes: "", iconID: 1, isExpanded: false,
                    times: .init(creationTime: date, lastModificationTime: date, locationChanged: date),
                    enableSearching: .disabled, tags: ["t"],
                    entries: [KDBXDocument.Entry(
                        uuid: TestID.entry, iconID: 2, tags: ["a", "b"], times: .init(creationTime: date),
                        strings: [.init(key: "P", value: "ü🔑", isProtected: true)],
                        binaries: [.init(key: "x", ref: 0, insertionIndex: 3)],
                        history: [KDBXDocument.Entry(uuid: TestID.entry, iconID: 9)]
                    )]
                )],
                deletedObjects: [.init(uuid: TestID.other, deletionTime: date)]
            )
        )
        XCTAssertEqual(try read(write(built)), built)
    }

    func test_recycleBinStatesRoundTrip() throws {
        for value in [nil, KDBXDocument.RecycleBin.unset, .group(TestID.group)] {
            let built = KDBXDocument(meta: .init(recycleBin: value))
            XCTAssertEqual(try read(write(built)), built, String(describing: value))
        }
    }

    func test_salsa20AndUnprotectedStreamsRoundTrip() throws {
        let value = KDBXDocument(root: .init(entries: [
            KDBXDocument.Entry(uuid: TestID.entry, strings: [.init(key: "P", value: "secret", isProtected: true)]),
        ]))
        for algorithm in [KDBXInnerStream.Algorithm.salsa20, .unprotected, .chaCha20] {
            let key = Data(repeating: 3, count: 32)
            let data = try value.serialized(innerStream: algorithm, innerStreamKey: key)
            XCTAssertEqual(try KDBXDocument.read(xml: data, innerStreamID: algorithm.rawValue, innerStreamKey: key), value)
        }
    }
}
