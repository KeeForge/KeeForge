import Foundation
import KDBXKit
import XCTest
@testable import KDBXXML

enum Fixture {
    struct Payload {
        let xml: Data
        let streamID: UInt32
        let streamKey: Data

        func read() throws -> KDBXDocument {
            try KDBXDocument.read(xml: xml, innerStreamID: streamID, innerStreamKey: streamKey)
        }
    }

    static func payload(_ name: String) throws -> Payload {
        let xml = try data("\(name).xml")
        let fields = String(decoding: try data("\(name).stream"), as: UTF8.self).split(separator: " ")
        return Payload(
            xml: xml,
            streamID: try XCTUnwrap(UInt32(fields[0])),
            streamKey: Data(hex: String(fields[1]))
        )
    }

    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }
}

/// A ChaCha20 stream with a fixed key, as the writer always uses.
enum TestStream {
    static let key = Data(repeating: 0x5A, count: 64)

    static func make() -> KDBXInnerStream {
        // Fixed valid parameters; cannot throw.
        try! KDBXInnerStream(algorithm: .chaCha20, key: key)
    }

    /// `values` masked in order, base64-encoded, as a writer would emit them.
    static func masked(_ values: [String]) -> [String] {
        var stream = make()
        return values.map { stream.apply(Data($0.utf8)).base64EncodedString() }
    }
}

/// Reads payload XML given as a string with the test stream.
func read(_ xml: String) throws -> KDBXDocument {
    try KDBXDocument.read(xml: Data(xml.utf8), innerStreamID: KDBXInnerStream.Algorithm.chaCha20.rawValue, innerStreamKey: TestStream.key)
}

/// The serialized document as a string without the BOM and XML declaration.
func write(_ document: KDBXDocument) throws -> String {
    let data = try document.serialized(innerStream: .chaCha20, innerStreamKey: TestStream.key)
    let text = String(decoding: data, as: UTF8.self)
    let prolog = "\u{FEFF}<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>\n"
    XCTAssertTrue(text.hasPrefix(prolog))
    return String(text.dropFirst(prolog.count))
}

/// `<KeePassFile><Meta/><Root>…</Root></KeePassFile>` around `root`.
func document(root: String, meta: String = "") -> String {
    "<KeePassFile><Meta>\(meta)</Meta><Root>\(root)</Root></KeePassFile>"
}

/// A group around `body` with a fixed UUID.
func group(_ body: String) -> String {
    "<Group><UUID>\(TestID.group.kdbxBase64String)</UUID><Name>G</Name>\(body)</Group>"
}

/// An entry around `body` with a fixed UUID.
func entry(_ body: String) -> String {
    "<Entry><UUID>\(TestID.entry.kdbxBase64String)</UUID>\(body)</Entry>"
}

enum TestID {
    static let group = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let entry = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let other = UUID(uuidString: "4D9C2B1E-7A35-4E68-9B0D-52F16C8A3E77")!
}

extension Data {
    /// Test-only; traps on malformed input.
    init(hex: String) {
        let digits = Array(hex.filter { !$0.isWhitespace })
        precondition(digits.count.isMultiple(of: 2))
        self.init(stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
    }
}

extension Date {
    /// Whole seconds since 1970, which survive KDBX's second resolution.
    init(unix seconds: Int) {
        self.init(timeIntervalSince1970: TimeInterval(seconds))
    }
}

func assertThrows<E: Error & Equatable>(
    _ expected: E,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () throws -> some Any
) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
        XCTAssertEqual(error as? E, expected, "got \(error)", file: file, line: line)
    }
}
