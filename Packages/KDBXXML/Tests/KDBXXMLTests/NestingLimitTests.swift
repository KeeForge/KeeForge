import Foundation
import KDBXKit
import XCTest
@testable import KDBXXML

final class NestingLimitTests: XCTestCase {
    private let limit = KDBXDocument.maxElementDepth
    /// Root groups sit at depth 3 and a group's `Times` children two below it.
    private var deepestGroupNesting: Int { limit - 4 }

    // MARK: - Reading

    func test_read_acceptsTheLimitAndRefusesOneMore() throws {
        // `<KeePassFile><Root>` plus `limit - 2` more levels reaches the limit.
        let atLimit = nestedGroupsXML(count: limit - 2)
        XCTAssertEqual(try depth(of: read(atLimit).root.groups.first), limit - 2)

        assertThrows(KDBXDocument.ReadError.nestingTooDeep) {
            try read(nestedGroupsXML(count: limit - 1))
        }
    }

    func test_read_countsUnknownElementsToo() {
        let xml = "<KeePassFile><Meta>" + String(repeating: "<X>", count: limit - 1)
            + String(repeating: "</X>", count: limit - 1) + "</Meta><Root/></KeePassFile>"
        assertThrows(KDBXDocument.ReadError.nestingTooDeep) { try read(xml) }
    }

    func test_read_refusesAHostileDepthWithoutOverflowingASmallStack() {
        let hostile = Data(nestedGroupsXML(count: 200_000).utf8)
        let outcome = onSmallStack {
            Result { try Self.readData(hostile) }.map { _ in () }
        }
        XCTAssertEqual(outcome.failure as? KDBXDocument.ReadError, .nestingTooDeep)
    }

    // MARK: - Writing

    func test_write_atTheLimitReadsBackAndSurvivesASmallStack() throws {
        let document = nestedGroupsDocument(count: deepestGroupNesting)
        let written = try Self.writeData(document)
        XCTAssertEqual(try Self.writeData(Self.readData(written)), written)

        let outcome = onSmallStack {
            Result { _ = try Self.writeData(Self.readData(written)) }
        }
        XCTAssertNil(outcome.failure)
    }

    func test_write_refusesAGroupOneLevelTooDeep() {
        let document = nestedGroupsDocument(count: deepestGroupNesting + 1)
        let deepest = innermost(document.root.groups[0])
        assertThrows(KDBXDocument.WriteError.nestingTooDeep(at: .group(deepest.uuid))) {
            try document.serialized(innerStream: .chaCha20, innerStreamKey: TestStream.key)
        }
    }

    func test_write_refusesAnEntryOrHistoryVersionTooDeep() {
        let entry = KDBXDocument.Entry()
        var document = nestedGroupsDocument(count: deepestGroupNesting, innermostEntries: [entry])
        assertThrows(KDBXDocument.WriteError.nestingTooDeep(at: .entry(entry.uuid))) {
            try document.serialized(innerStream: .chaCha20, innerStreamKey: TestStream.key)
        }

        let version = KDBXDocument.Entry()
        let owner = KDBXDocument.Entry(history: [version])
        document = nestedGroupsDocument(count: deepestGroupNesting - 2, innermostEntries: [owner])
        assertThrows(KDBXDocument.WriteError.nestingTooDeep(at: .historyEntry(version.uuid))) {
            try document.serialized(innerStream: .chaCha20, innerStreamKey: TestStream.key)
        }
    }

    func test_write_measuresFragmentsWhereTheyLand() throws {
        func nested(_ count: Int) -> String {
            String(repeating: "<X>", count: count) + String(repeating: "</X>", count: count)
        }
        func fragments(_ count: Int, path: [String] = []) -> OpaqueXMLNodes {
            OpaqueXMLNodes(nodes: [.init(path: path, insertionIndex: 0, xml: nested(count))])
        }

        // Owner depth plus path plus fragment depth may reach the limit, not pass it.
        XCTAssertNoThrow(try Self.writeData(KDBXDocument(meta: .init(unknownXML: fragments(limit - 2)))))
        assertThrows(KDBXDocument.WriteError.nestingTooDeep(at: .document)) {
            try KDBXDocument(unknownXML: fragments(self.limit))
                .serialized(innerStream: .chaCha20, innerStreamKey: TestStream.key)
        }
        assertThrows(KDBXDocument.WriteError.nestingTooDeep(at: .meta)) {
            try KDBXDocument(meta: .init(unknownXML: fragments(self.limit - 1)))
                .serialized(innerStream: .chaCha20, innerStreamKey: TestStream.key)
        }
        assertThrows(KDBXDocument.WriteError.nestingTooDeep(at: .root)) {
            try KDBXDocument(root: .init(unknownXML: fragments(self.limit - 1)))
                .serialized(innerStream: .chaCha20, innerStreamKey: TestStream.key)
        }

        let group = KDBXDocument.Group(unknownXML: fragments(limit - 3, path: ["Times"]))
        assertThrows(KDBXDocument.WriteError.nestingTooDeep(at: .group(group.uuid))) {
            try KDBXDocument(root: .init(groups: [group]))
                .serialized(innerStream: .chaCha20, innerStreamKey: TestStream.key)
        }

        let entry = KDBXDocument.Entry(unknownXML: fragments(limit - 2))
        assertThrows(KDBXDocument.WriteError.nestingTooDeep(at: .entry(entry.uuid))) {
            try KDBXDocument(root: .init(entries: [entry]))
                .serialized(innerStream: .chaCha20, innerStreamKey: TestStream.key)
        }
    }

    func test_elementDepth_countsOpeningTagsOnly() {
        XCTAssertEqual(XMLText.elementDepth(of: ""), 0)
        XCTAssertEqual(XMLText.elementDepth(of: "<A>x</A>"), 1)
        XCTAssertEqual(XMLText.elementDepth(of: "<A><B>&lt;b&gt;</B><C><D></D></C></A>"), 3)
    }

    // MARK: - Helpers

    private func nestedGroupsXML(count: Int) -> String {
        "<KeePassFile><Root>" + String(repeating: "<Group>", count: count)
            + String(repeating: "</Group>", count: count) + "</Root></KeePassFile>"
    }

    /// Groups with times set, so each writes `Times` children at its deepest level.
    private func nestedGroupsDocument(count: Int, innermostEntries: [KDBXDocument.Entry] = []) -> KDBXDocument {
        let times = KDBXDocument.Times(creationTime: Date(timeIntervalSince1970: 0))
        var group = KDBXDocument.Group(name: "1", times: times, entries: innermostEntries)
        for level in 2...count {
            group = KDBXDocument.Group(name: String(level), times: times, groups: [group])
        }
        return KDBXDocument(root: .init(groups: [group]))
    }

    private func innermost(_ group: KDBXDocument.Group) -> KDBXDocument.Group {
        var current = group
        while let child = current.groups.first { current = child }
        return current
    }

    private func depth(of group: KDBXDocument.Group?) -> Int {
        var levels = 0
        var current = group
        while let group = current {
            levels += 1
            current = group.groups.first
        }
        return levels
    }

    private static func writeData(_ document: KDBXDocument) throws -> Data {
        try document.serialized(innerStream: .chaCha20, innerStreamKey: TestStream.key)
    }

    private static func readData(_ data: Data) throws -> KDBXDocument {
        try KDBXDocument.read(xml: data, innerStreamID: KDBXInnerStream.Algorithm.chaCha20.rawValue, innerStreamKey: TestStream.key)
    }

    /// Runs `work` on a 512 KiB stack, the size of the background threads
    /// the app opens and saves on.
    private func onSmallStack(_ work: @escaping @Sendable () -> Result<Void, Error>) -> Result<Void, Error> {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.result = work()
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        return box.result
    }
}

private final class ResultBox: @unchecked Sendable {
    var result: Result<Void, Error> = .success(())
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
