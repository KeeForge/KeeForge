import Foundation
import XCTest
@testable import KeeForge

final class GoogleDrivePickerSelectionTests: XCTestCase {
    func testReturnsTheSelectedFileIDUnchanged() {
        let parameters: [String: NSObject & NSCopying] = ["picked_file_ids": "Synthetic_File-01" as NSString]
        let result = GoogleDrivePickerSelection.fileID(from: parameters)

        XCTAssertEqual(result, "Synthetic_File-01")
    }

    func testRejectsMissingOrNonStringSelection() {
        XCTAssertNil(GoogleDrivePickerSelection.fileID(from: nil))
        XCTAssertNil(GoogleDrivePickerSelection.fileID(from: [:]))
        XCTAssertNil(GoogleDrivePickerSelection.fileID(from: ["picked_file_ids": ["Synthetic_File-01"]]))
    }

    func testRejectsMultipleFilesAndMalformedIDs() {
        for value in ["", "one,two", "one,one", "one,", " one", "one\n", "one/two", "one%2Ftwo", "one?two", "é"] {
            XCTAssertNil(GoogleDrivePickerSelection.fileID(from: ["picked_file_ids": value]), value.debugDescription)
        }
    }
}
