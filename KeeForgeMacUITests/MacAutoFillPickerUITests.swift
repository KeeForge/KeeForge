import XCTest

/// The Mac AutoFill picker's add-website action (#122), driven through the
/// DEBUG-only `-autofill-picker-harness` root, which hosts the same
/// `AutoFillSearchView` and its in-view Mac chrome as the extension panel.
/// A UI test because the confirmation is a SwiftUI alert, which no unit test
/// can open; what a confirmed addition writes is covered by
/// `CredentialProviderCoordinatorTests`.
@MainActor
final class MacAutoFillPickerUITests: MacUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        app.launchArguments += ["-autofill-picker-harness"]
    }

    func testSearchResultOffersTheRequestedHostAndConfirmsWithItsSavedURLs() {
        let searchField = app.textFields["autofill.search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 15), "The picker's search field did not appear")
        searchField.click()
        searchField.typeText("Bank")

        let row = entryRow()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The search found no row for Bank")
        row.rightClick()
        let addURL = addWebsiteMenuItem()
        XCTAssertTrue(addURL.waitForExistence(timeout: 5), "The row's context menu must offer adding the website")
        XCTAssertTrue(
            [addURL.title, addURL.label].contains("Add login.example.com to This Entry"),
            "The action must name the host"
        )
        addURL.click()

        XCTAssertTrue(waitForText(containing: "Add Website to Entry?"), "The confirmation did not appear")
        for expected in ["“login.example.com”", "“Bank”", "https://bank.test", "Caution:"] {
            XCTAssertTrue(waitForText(containing: expected, timeout: 2), "The confirmation must show \(expected)")
        }

        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ OR title == %@", "Add Website", "Add Website"))
            .allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(confirm, "The confirmation's Add Website button was missing")
        confirm?.click()
        XCTAssertTrue(
            waitForDisplayText("added https://login.example.com to Bank", identifier: "autofill-harness.result"),
            "Confirming must hand the entry to the add action"
        )
    }

    func testEntryAlreadyStoringTheHostOffersNoAddAction() {
        let searchField = app.textFields["autofill.search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 15))
        searchField.click()
        searchField.typeText("Example Login")

        let row = entryRow()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.rightClick()
        XCTAssertFalse(addWebsiteMenuItem().waitForExistence(timeout: 2), "An entry storing the host offered to add it again")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// A match or possible match; the harness decides which section a search lands in.
    private func entryRow() -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier IN %@", ["autofill.entry.exact", "autofill.entry.possible.use"])
        ).firstMatch
    }

    private func addWebsiteMenuItem() -> XCUIElement {
        app.menuItems.matching(
            NSPredicate(
                format: "(identifier IN %@ OR title ENDSWITH %@) AND isEnabled == true",
                ["autofill.entry.add-url", "autofill.entry.possible.add-url"],
                " to This Entry"
            )
        ).firstMatch
    }

    /// Mac `Text` reports through `value` with an empty `label`, so match both.
    private func waitForText(containing text: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        return app.staticTexts.matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }
}
