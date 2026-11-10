import UniformTypeIdentifiers
import XCTest
@testable import KeeForge

final class KeyFileExportDocumentTests: XCTestCase {
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
}
