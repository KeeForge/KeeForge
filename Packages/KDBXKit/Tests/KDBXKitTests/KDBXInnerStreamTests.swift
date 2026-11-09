import CryptoKit
import XCTest
@testable import KDBXKit

final class KDBXInnerStreamTests: XCTestCase {
    private static let streamKey = Data((0..<64).map { UInt8($0) })

    func testAlgorithmRawValuesMatchTheHeader() {
        XCTAssertEqual(KDBXInnerStream.Algorithm.allCases.map(\.rawValue), [0, 1, 2, 3])
    }

    func testUnprotectedPassesValuesThrough() throws {
        var stream = try KDBXInnerStream(algorithm: .unprotected, key: Data())
        XCTAssertEqual(stream.apply(Data("plain".utf8)), Data("plain".utf8))
    }

    func testRejectsArcFourAndUnknownStreams() {
        assertThrows(KDBXContainer.ParseError.unsupportedProtectedFieldStream(1)) {
            try KDBXInnerStream(algorithm: .arcFourVariant, key: Self.streamKey)
        }
        assertThrows(KDBXContainer.ParseError.unsupportedProtectedFieldStream(99)) {
            try KDBXInnerStream(streamID: 99, key: Self.streamKey)
        }
    }

    /// KeePass's Salsa20 stream: key SHA-256(stream key), fixed nonce
    /// E830094B97205D2A. The expected bytes come from a Python Salsa20 that
    /// reproduces eSTREAM set 1 vector 0 (`e3be8fdd8beca2e3...`).
    func testSalsa20MatchesIndependentKeystream() throws {
        let expected = Data(hex: """
            0f49b2bd1392f303c02eef124cd0fda0d1855645eb16470cb5aadc7698fb7bede27ee7b99216b0be573bb128a66cdcb16e916294edda057d95ce8a3623c45367\
            3debecbc923fcf6ab4062d098aef752ed9bd447787ac562ee9ed4fef1b0f08a48d0a192bbaff79c414efe362799f8ac3d7fea498a4d529cf4b08ff6882cc7fd1\
            8eee72f79bd230928400832175a3b1f7180819993f1fe822dbbdc319caf7532ef85f2300780758106fb7a2875425b70e2b9fd2b3c4c69da7addb485b0dc0fb15\
            ea99a2ba2ccd3127
            """)
        var single = try KDBXInnerStream(algorithm: .salsa20, key: Self.streamKey)
        XCTAssertEqual(single.apply(Data(count: expected.count)), expected)

        var chunked = try KDBXInnerStream(streamID: 2, key: Self.streamKey)
        var output = Data()
        var start = 0
        for length in [63, 1, 0, 64, 65, 7] {
            output += chunked.apply(Data(count: length))
            start += length
        }
        XCTAssertEqual(output, expected)
    }

    /// Python `cryptography` ChaCha20 under the KDBX 4 convention: key and
    /// nonce from SHA-512(stream key), one keystream across values.
    func testChaCha20MatchesKnownAnswerVectorsAcrossBlockBoundaries() throws {
        let vectors: [(String, String)] = [
            (String(repeating: "a", count: 63),
             "ed89dd006ba13e9382bce9d5fb7565a3e52e75e156631517d95c399401fbbe04999be6b9d494491e0d9cdcd7fbbfc3982385cd94c8ccffe76742261b12c32d"),
            ("b", "2c"),
            (String(repeating: "c", count: 64),
             "59517b9f6065d3f6c48466bc0fd35c9f3a4e4f8580cad90f391bcbdfe8f3e912b1f0f73a95235d06f8c723884cc92533801bdd558bfbb855094e0c4b363e1582"),
            (String(repeating: "d", count: 65),
             "0cbf562ce13840b9b0ef1983bf87856d966c9769f7ca89b9f837e30740d417b400d4750f6e8a786d9ea8effd54cb69183277328a2c6a7793f114296a71deee3b52"),
            (String(repeating: "e", count: 200), """
             216d0d93741cd781a6b6348b30a873ba00ea5f761736c8ffe0685cfc30ae23b8f8248dca974f2edfab49fe33003b4b8ffdaace1cc06d3bddb9ecd0dd504b54cd\
             a5add87d0bd8fc9b000ad0599f0e91bf3c9b574ee749cce2efb1dbded229f5e59994bf22680ab6b3223ff8e326394563061175ae156cb61e57fdc586dd995b99\
             1cfcfffbc010582a1ed24c82d651e898b3476e05ea6306091f93275ddd31fcc0c355c3fa464ab66ea78425615bccb53e3c6caf8d0816fa456b7d67a6573ebb74\
             c09f9b6707d283da
             """),
        ]
        var stream = try KDBXInnerStream(algorithm: .chaCha20, key: Self.streamKey)
        var decoder = try KDBXInnerStream(streamID: 3, key: Self.streamKey)
        for (plaintext, ciphertext) in vectors {
            XCTAssertEqual(stream.apply(Data(plaintext.utf8)), Data(hex: ciphertext), "\(plaintext.count) bytes")
            XCTAssertEqual(decoder.apply(Data(hex: ciphertext)), Data(plaintext.utf8))
        }
    }

    /// Empty protected values must not consume keystream, or readers and
    /// writers that skip them would fall out of step.
    func testEmptyValuesDoNotConsumeKeystream() throws {
        for algorithm in [KDBXInnerStream.Algorithm.salsa20, .chaCha20] {
            var withEmpties = try KDBXInnerStream(algorithm: algorithm, key: Self.streamKey)
            XCTAssertEqual(withEmpties.apply(Data()), Data())
            let first = withEmpties.apply(Data(count: 10))
            XCTAssertEqual(withEmpties.apply(Data()), Data())
            let second = withEmpties.apply(Data(count: 10))

            var reference = try KDBXInnerStream(algorithm: algorithm, key: Self.streamKey)
            XCTAssertEqual(first + second, reference.apply(Data(count: 20)), "\(algorithm)")
        }
    }

    /// The KDBX 3.1 fixture's protected values, decoded in document order,
    /// include the Twitter password a KeePassXC user entered.
    func testSalsa20DecodesTheLegacyFixturesProtectedValues() throws {
        let payload = try KDBXContainer.read(data: Fixture.data("legacy-kdbx31.kdbx")) { _ in Fixture.legacyTransformedKey }
        XCTAssertEqual(payload.header.innerStreamID, KDBXInnerStream.Algorithm.salsa20.rawValue)
        let values = try Self.decodeProtectedValues(in: payload)
        XCTAssertTrue(values.contains("tw1tterP@ss!"), "\(values)")
    }

    /// Decodes every `Protected="True"` value in document order.
    static func decodeProtectedValues(in payload: KDBXContainer.Payload) throws -> [String] {
        var stream = try KDBXInnerStream(streamID: payload.header.innerStreamID, key: payload.header.innerStreamKey)
        let xml = String(decoding: payload.xml, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #"<Value Protected="True">([^<]*)</Value>"#)
        return regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).map { match in
            let base64 = String(xml[Range(match.range(at: 1), in: xml)!])
            return String(decoding: stream.apply(Data(base64Encoded: base64) ?? Data()), as: UTF8.self)
        }
    }
}
