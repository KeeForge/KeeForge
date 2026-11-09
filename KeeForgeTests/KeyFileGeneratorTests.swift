import CryptoKit
import UniformTypeIdentifiers
import XCTest
import KDBXKit
@testable import KeeForge

final class KeyFileGeneratorTests: XCTestCase {
    func testKeyFileIsKeePassXMLv2WithGroupedHexKeyAndMatchingHash() throws {
        let file = try KeyFileGenerator.makeKeyFile()
        let text = try XCTUnwrap(String(data: file, encoding: .utf8))
        let lines = text.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, #"<?xml version="1.0" encoding="utf-8"?>"#)
        XCTAssertTrue(text.contains("<Version>2.0</Version>"))

        let keyLines = lines.filter {
            $0.range(of: #"^\t\t\t[0-9A-F]{8}( [0-9A-F]{8}){3}$"#, options: .regularExpression) != nil
        }
        XCTAssertEqual(keyLines.count, 2)
        let key = try XCTUnwrap(dataFromHex(keyLines.joined().filter(\.isHexDigit)))
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(try KeyFileProcessor.processKeyFile(file), key)

        let hashRange = try XCTUnwrap(text.range(of: #"(?<=Hash=")[0-9A-F]{8}(?=")"#, options: .regularExpression))
        let expectedHash = SHA256.hash(data: key).prefix(4).map { String(format: "%02X", $0) }.joined()
        XCTAssertEqual(String(text[hashRange]), expectedHash)
    }

    func testEachKeyFileHasADifferentKey() throws {
        let keys = try (0..<3).map { _ in try KeyFileProcessor.processKeyFile(KeyFileGenerator.makeKeyFile()) }

        XCTAssertEqual(Set(keys).count, 3)
    }

    func testExportedKeyFileIsAKeyxFileNamedAfterTheDatabase() {
        XCTAssertEqual(KeyFileExportDocument.contentType.preferredFilenameExtension, "keyx")
        XCTAssertTrue(KeyFileExportDocument.contentType.conforms(to: .xml))
        XCTAssertEqual(KeyFileExportDocument.defaultFilename(forDatabaseFilename: "Personal.kdbx"), "Personal.keyx")
        XCTAssertEqual(KeyFileExportDocument.defaultFilename(forDatabaseFilename: "New Database.kdbx"), "New Database.keyx")
    }

    func testCancelledExportShowsNoAlertAndAFailedOneDoes() {
        XCTAssertNil(KeyFileExportDocument.creationFailureAlert(for: CocoaError(.userCancelled)))

        let alert = KeyFileExportDocument.creationFailureAlert(for: CocoaError(.fileWriteNoPermission))
        XCTAssertEqual(alert?.title, String(localized: "Couldn’t Create Key File"))
    }

    private func dataFromHex(_ hex: String) -> Data? {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
