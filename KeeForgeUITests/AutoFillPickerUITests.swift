import XCTest

/// The AutoFill picker's add-website action (#122), driven through the
/// DEBUG-only `-autofill-picker-harness` root: the real `AutoFillSearchView`
/// for a request from `login.example.com` over in-memory entries, so no
/// Safari or enabled provider is needed. What a confirmed addition writes is
/// covered by `CredentialProviderCoordinatorTests`.
/// It does not extend `KeeForgeUITestCase` because the harness replaces the
/// database-list root, so no fixture injection or unlock flow applies.
@MainActor
final class AutoFillPickerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        executionTimeAllowance = 300
        app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-autofill-picker-harness"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        try await super.tearDown()
    }

    func testSearchResultOffersTheRequestedHostAndConfirmsWithItsSavedURLs() {
        search(for: "Bank")

        let addURL = app.buttons["autofill.entry.add-url"].firstMatch
        XCTAssertTrue(addURL.waitForExistence(timeout: 10), "A search result must offer adding the website")
        XCTAssertTrue(addURL.label.contains("login.example.com"), "The action must name the host: \(addURL.label)")
        addURL.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts["Add Website to Entry?"].exists)
        for expected in ["“login.example.com”", "“Bank”", "https://bank.test", "Caution:"] {
            XCTAssertTrue(
                alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch.exists,
                "The confirmation must show \(expected)"
            )
        }

        alert.buttons["Add Website"].tap()
        let result = app.staticTexts["autofill-harness.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "added https://login.example.com to Bank")
    }

    func testEntryAlreadyStoringTheHostOffersNoAddAction() {
        search(for: "Example Login")

        XCTAssertTrue(app.buttons["autofill.entry.exact"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["autofill.entry.add-url"].exists)
    }

    func testPossibleMatchConfirmationNamesTheHostWithoutCaution() {
        let addURL = app.buttons["autofill.entry.possible.add-url"].firstMatch
        XCTAssertTrue(addURL.waitForExistence(timeout: 10))
        addURL.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "“login.example.com”")).firstMatch.exists)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "https://www.example.com")).firstMatch.exists)
        XCTAssertFalse(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Caution:")).firstMatch.exists)

        alert.buttons["Cancel"].tap()
        XCTAssertEqual(app.staticTexts["autofill-harness.result"].label, "none", "Cancelling must not add anything")
    }

    func testSearchMatchingNoPossibleMatchDropsTheirHeading() {
        let heading = app.staticTexts["Possible matches"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "The harness lists a possible match before searching")

        search(for: "Bank")

        XCTAssertTrue(app.buttons["autofill.entry.exact"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(heading.exists, "No possible match fits the search, so the heading must go")
    }

    func testSearchWithoutResultsOffersCreatingACredentialAndExplainsTheSharedCopy() {
        search(for: "zzz")

        XCTAssertTrue(app.descendants(matching: .any)["autofill.no-credentials-found"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["autofill.shared-copy-notice"].exists)
        let create = app.buttons["autofill.create-entry.empty-state"]
        XCTAssertTrue(create.exists)
        // On the closed iPhone Duo the active search bar floats over this row.
        app.searchFields["Search entries"].firstMatch.typeText("\n")
        create.tap()
        XCTAssertEqual(app.staticTexts["autofill-harness.result"].label, "create")
    }

    /// A request whose domain matches nothing lands on its pre-filled search;
    /// the empty state then names the site and offers a login for it.
    func testUnmatchedSiteOffersALoginForThatSite() {
        app.terminate()
        app.launchEnvironment["UI_TEST_AUTOFILL_HARNESS_SEARCH"] = "login.zeit.de"
        app.launch()

        let title = app.staticTexts["autofill.no-credentials-found"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, "Nothing for this site yet")
        XCTAssertTrue(app.staticTexts["login.zeit.de"].exists, "The empty state must name the site")
        XCTAssertTrue(app.buttons["autofill.show-all-entries.empty-state"].exists)
        let create = app.buttons["autofill.create-entry.empty-state"]
        XCTAssertTrue(create.exists)
        create.tap()
        XCTAssertEqual(app.staticTexts["autofill-harness.result"].label, "create")
    }

    private func search(for query: String, file: StaticString = #filePath, line: UInt = #line) {
        let searchField = app.searchFields["Search entries"].firstMatch
        if searchField.waitForExistence(timeout: 5) == false {
            app.expandCollapsedSearch()
        }
        XCTAssertTrue(searchField.waitForExistence(timeout: 15), "Search field was not visible", file: file, line: line)
        searchField.tap()
        searchField.typeText(query)
    }
}
