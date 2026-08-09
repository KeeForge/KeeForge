import XCTest

/// Smoke coverage for the Finder/iTunes File Sharing surfaces (#63): KDBX
/// files living in the app's Documents directory. Fixtures are seeded through
/// the `documents-*` payload dispositions; Finder replace/rebind edge cases
/// stay unit-tested in `DocumentsVaultScannerTests`.
@MainActor
final class DocumentsVaultUITests: KeeForgeUITestCase {
    override var databaseFixtures: [KeeForgeUITestCase.DatabaseFixture] {
        [
            .init(resourceName: "test", injectedFilename: "dropped.kdbx", disposition: .documentsUnregistered),
            .init(resourceName: "test", injectedFilename: "vanished.kdbx", disposition: .documentsMissing),
        ]
    }

    func testDroppedFileIsAutoRegisteredAndUnlocks() {
        let droppedRow = databaseRow(containing: "dropped")
        XCTAssertTrue(
            droppedRow.waitForExistence(timeout: Self.ciElementTimeout),
            "Launch scan did not register the KDBX file dropped into Documents"
        )

        openDatabase(named: "dropped")
        unlock(password: "testpassword123")
        waitForVaultToUnlock()
    }

    func testMissingResidentFileShowsBadgeAndRemoveFlow() {
        XCTAssertTrue(
            databaseRow(containing: "vanished").waitForExistence(timeout: Self.ciElementTimeout),
            "Missing-file database row did not appear"
        )

        let missingBadge = app.staticTexts["database-row.documents-file-missing"]
        XCTAssertTrue(
            missingBadge.waitForExistence(timeout: Self.ciElementTimeout),
            "Missing-file caption did not appear on the database row"
        )

        // The file read fails before the password is checked, so any password
        // reaches the open-failure screen that offers the removal action.
        openDatabase(named: "vanished")
        unlock(password: "testpassword123")

        let removeButton = app.buttons["unlock.remove-missing"]
        XCTAssertTrue(
            removeButton.waitForExistence(timeout: Self.ciElementTimeout),
            "Remove from List was not offered for the missing Documents file"
        )
        tapElement(removeButton)

        let confirmButton = app.buttons["Remove"].firstMatch
        XCTAssertTrue(
            confirmButton.waitForExistence(timeout: Self.ciElementTimeout),
            "Remove confirmation dialog did not appear"
        )
        confirmButton.tap()

        XCTAssertTrue(
            databaseRow(containing: "dropped").waitForExistence(timeout: Self.ciElementTimeout),
            "Database list did not come back after removal"
        )

        let removedRow = databaseRow(containing: "vanished")
        let deadline = Date().addingTimeInterval(10)
        while removedRow.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(removedRow.exists, "Removed database still appears in the list")
    }
}
