import XCTest

@MainActor
final class UnlockedDatabaseUITests: KeeForgeUITestCase {

    override func setUp() async throws {
        continueAfterFailure = true
        try await super.setUp()
    }

    func testNavigation() {
        unlockSuccessfully()
        verifyNavigation()
    }

    func testEntryDetail() {
        unlockSuccessfully()
        verifyEntryDetail()
    }

    func testEntryTimestamps() {
        unlockSuccessfully()
        verifyEntryTimestamps()
    }

    func testSearchStaysActiveWhileTyping() {
        unlockSuccessfully()
        verifySearchStaysActiveWhileTyping()
    }

    func testSearchShowsMatchesAndNoResults() {
        unlockSuccessfully()
        verifySearchShowsMatchesAndNoResults()
    }

    func testSortMenuShowsOptions() {
        unlockSuccessfully()
        verifySortMenuShowsOptions()
    }

    func testSortOrderChangeWorks() {
        unlockSuccessfully()
        verifySortOrderChangeWorks()
    }

    func testSettingsPageContent() {
        unlockSuccessfully()
        verifySettingsPageContent()
    }

    func testTipJarContent() {
        unlockSuccessfully()
        verifyTipJarContent()
    }

    // MARK: - Navigation (from NavigationUITests)

    private func verifyNavigation() {
        XCTAssertTrue(openAnyEntry(maxDepth: 8), "No entry found while navigating groups")

        let anyCopyButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entry.copy.")).firstMatch
        XCTAssertTrue(anyCopyButton.waitForExistence(timeout: 5), "Entry detail did not open")
    }

    // MARK: - Entry Detail (from EntryDetailUITests)

    private func verifyEntryDetail() {
        XCTAssertTrue(openAnyEntry(), "Could not find an entry to open")

        let copyQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "entry.copy."))
        XCTAssertTrue(copyQuery.firstMatch.waitForExistence(timeout: 5), "No copy actions found in entry detail")

        let tapCount = min(copyQuery.count, 3)
        XCTAssertGreaterThan(tapCount, 0)
        for index in 0..<tapCount {
            copyQuery.element(boundBy: index).tap()
        }

        let revealButton = app.buttons["entry.password.reveal"]
        if revealButton.exists {
            revealButton.tap()
            let passwordCopy = app.buttons["entry.copy.password"]
            if passwordCopy.exists {
                passwordCopy.tap()
            }
        }

        let urlCopy = app.buttons["entry.copy.url"]
        if urlCopy.exists {
            urlCopy.tap()
        }
    }

    // MARK: - Entry Timestamps (from EntryTimestampUITests)

    private func verifyEntryTimestamps() {
        XCTAssertTrue(openAnyEntry(), "Could not open any entry")

        // Scroll down to find the Details section with timestamps
        let detailList = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0..<4 {
            detailList.swipeUp()
        }

        // Check for "Created" or "Modified" labels in the Details section
        let createdLabel = app.staticTexts["Created"]
        let modifiedLabel = app.staticTexts["Modified"]

        let hasTimestamp = createdLabel.exists || modifiedLabel.exists
        XCTAssertTrue(hasTimestamp, "Entry detail should show Created or Modified timestamp")
    }

    // MARK: - Search helpers (from SearchUITests)

    private func debugSearchHierarchy(_ stage: String, file: StaticString = #filePath, line: UInt = #line) {
        let promptMatchCount = app.descendants(matching: .any).matching(identifier: "Search entries").count
        let searchFieldCount = app.searchFields.count
        let textFieldCount = app.textFields.count
        let searchButtonCount = app.buttons.matching(identifier: "Search").count
        let navBarCount = app.navigationBars.count
        let tableCount = app.tables.count
        let collectionCount = app.collectionViews.count
        let scrollViewCount = app.scrollViews.count
        let navSearchButtonCount = app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Search'")).count

        let summary = """
        [SearchUITests] \(stage)
          navigationBars=\(navBarCount) tables=\(tableCount) collectionViews=\(collectionCount) scrollViews=\(scrollViewCount)
          searchFields=\(searchFieldCount) textFields=\(textFieldCount)
          buttons[Search]=\(searchButtonCount) navButtons[label~Search]=\(navSearchButtonCount) descendants[id=Search entries]=\(promptMatchCount)
        """
        NSLog("%@", summary)

        let attachment = XCTAttachment(string: "[\(stage)]\n\(app.debugDescription)")
        attachment.name = "Search hierarchy - \(stage)"
        attachment.lifetime = .keepAlways
        add(attachment)

        if !app.navigationBars.firstMatch.exists {
            XCTFail("Navigation bar is missing at \(stage)", file: file, line: line)
        }
    }

    private func findSearchInput(timeout: TimeInterval) -> XCUIElement? {
        let candidates: [XCUIElement] = [
            app.searchFields["Search entries"],
            app.searchFields.firstMatch,
            app.textFields["Search entries"],
            app.textFields.firstMatch
        ]

        for candidate in candidates where candidate.waitForExistence(timeout: timeout) {
            return candidate
        }

        return nil
    }

    private func tapSearchButtonIfPresent(timeout: TimeInterval) -> Bool {
        let candidates: [XCUIElement] = [
            app.navigationBars.buttons["Search"].firstMatch,
            app.buttons["Search"].firstMatch,
            app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Search'")).firstMatch,
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Search'")).firstMatch
        ]

        for button in candidates where button.waitForExistence(timeout: timeout) {
            button.tap()
            return true
        }

        return false
    }

    private func activateSearchField(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        debugSearchHierarchy("before-search-activation", file: file, line: line)

        if let searchInput = findSearchInput(timeout: 1) {
            searchInput.tap()
            return searchInput
        }

        if tapSearchButtonIfPresent(timeout: 1), let searchInput = findSearchInput(timeout: 1) {
            searchInput.tap()
            return searchInput
        }

        let swipeTargets: [XCUIElement] = [
            app.collectionViews.firstMatch,
            app.tables.firstMatch,
            app.scrollViews.firstMatch,
            app.navigationBars.firstMatch
        ]

        for _ in 0..<3 {
            for target in swipeTargets where target.waitForExistence(timeout: 1) {
                target.swipeDown()

                if tapSearchButtonIfPresent(timeout: 1), let searchInput = findSearchInput(timeout: 1) {
                    searchInput.tap()
                    return searchInput
                }

                if let searchInput = findSearchInput(timeout: 1) {
                    searchInput.tap()
                    return searchInput
                }
            }
        }

        debugSearchHierarchy("search-field-missing-after-fallback", file: file, line: line)
        let fallbackField = app.searchFields.firstMatch
        XCTAssertTrue(
            fallbackField.waitForExistence(timeout: 5),
            "Search field did not appear",
            file: file,
            line: line
        )
        fallbackField.tap()
        return fallbackField
    }

    private func clearSearchField(_ searchField: XCUIElement) {
        let clearButton = searchField.buttons["Clear text"]
        if clearButton.exists {
            clearButton.tap()
            return
        }

        let currentValue = (searchField.value as? String) ?? ""
        if currentValue.isEmpty || currentValue == "Search entries" {
            return
        }

        let deleteSequence = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
        searchField.typeText(deleteSequence)
    }

    private func dismissSearchIfNeeded(timeout: TimeInterval = 5) {
        if let searchField = findSearchInput(timeout: 1) {
            searchField.tap()
            clearSearchField(searchField)
        }

        let keyboardSearchButton = app.buttons["Search"]
        if keyboardSearchButton.exists && keyboardSearchButton.isHittable {
            keyboardSearchButton.tap()
        }

        let cancelButton = app.buttons["Cancel"]
        if cancelButton.exists && cancelButton.isHittable {
            cancelButton.tap()
        }

        let navigationBar = app.navigationBars.firstMatch
        if navigationBar.exists {
            navigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let searchField = findSearchInput(timeout: 0.2) {
                clearSearchField(searchField)
            } else {
                return
            }

            if cancelButton.exists && cancelButton.isHittable {
                cancelButton.tap()
            }

            if keyboardSearchButton.exists && keyboardSearchButton.isHittable {
                keyboardSearchButton.tap()
            }

            if navigationBar.exists {
                navigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
    }

    // MARK: - Search (from SearchUITests)

    private func verifySearchStaysActiveWhileTyping() {
        let searchField = activateSearchField()

        // Type a multi-character query in one go — this is the real user flow
        searchField.typeText("Twi")

        // Search field should still exist (not dismissed after typing)
        let activeSearchField = findSearchInput(timeout: 5)
        XCTAssertNotNil(activeSearchField, "Search field disappeared after typing")

        // Verify results appeared (we have a "Twitter" entry)
        let resultsCountLabel = app.staticTexts["search.results.count"]
        if resultsCountLabel.waitForExistence(timeout: 5) {
            XCTAssertNotEqual(resultsCountLabel.label, "results:0", "Expected search results for 'Twi'")
        }

        dismissSearchIfNeeded()
    }

    private func verifySearchShowsMatchesAndNoResults() {
        let searchField = activateSearchField()
        clearSearchField(searchField)

        // `test.kdbx` always includes a Twitter entry, so use a stable fixture-backed query.
        searchField.typeText("Twitter\n")

        let resultsCountLabel = app.staticTexts["search.results.count"]
        XCTAssertTrue(resultsCountLabel.waitForExistence(timeout: 5), "Search results count label did not appear")
        XCTAssertFalse(resultsCountLabel.label == "results:0", "Expected at least one search result")

        searchField.tap()
        clearSearchField(searchField)

        let refocusedSearchField = activateSearchField()
        refocusedSearchField.typeText("___unlikely_query___\n")

        let timeout = Date().addingTimeInterval(5)
        var didReachZeroResults = false
        repeat {
            if resultsCountLabel.label == "results:0" {
                didReachZeroResults = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < timeout

        XCTAssertTrue(didReachZeroResults, "Expected no-results state")

        dismissSearchIfNeeded()
    }

    // MARK: - Sort helpers (from SortUITests)

    private func waitForAnyListContent(timeout: TimeInterval = 10) -> Bool {
        let entry = app.buttons.matching(identifier: "entry.navlink").firstMatch
        let group = app.buttons.matching(identifier: "group.navlink").firstMatch
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if entry.exists || group.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        return false
    }

    // MARK: - Sort (from SortUITests)

    private func verifySortMenuShowsOptions() {
        // Sort menu should exist and open
        let sortMenu = app.buttons["sort.menu"]
        XCTAssertTrue(sortMenu.waitForExistence(timeout: 10), "Sort menu button not found in toolbar")
        sortMenu.tap()

        // Should show sort options: Title, Date Created, Date Modified
        let titleOption = app.buttons["Title"]
        XCTAssertTrue(titleOption.waitForExistence(timeout: 5), "Sort menu should show sort order options")

        // Dismiss by tapping elsewhere
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    }

    private func verifySortOrderChangeWorks() {
        let sortMenu = app.buttons["sort.menu"]
        XCTAssertTrue(sortMenu.waitForExistence(timeout: 10), "Sort menu not found")
        sortMenu.tap()

        // Select "Date Modified"
        let modifiedOption = app.buttons["Date Modified"]
        XCTAssertTrue(modifiedOption.waitForExistence(timeout: 5), "Date Modified option not found")
        modifiedOption.tap()

        // Verify the list still displays entries (sort didn't crash)
        let hasContent = waitForAnyListContent(timeout: 10)
        XCTAssertTrue(hasContent, "List should still show entries/groups after changing sort order")
    }

    // MARK: - Settings helpers (from SettingsUITests)

    private func openSettings() {
        let settingsButton = app.buttons["settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "Settings button not found")
        settingsButton.tap()
    }

    private func settingsForm() -> XCUIElement {
        let candidates: [XCUIElement] = [
            app.collectionViews.firstMatch,
            app.tables.firstMatch,
            app.scrollViews.firstMatch,
        ]

        for candidate in candidates where candidate.exists {
            return candidate
        }

        return app.collectionViews.firstMatch
    }

    private func revealInSettings(_ element: XCUIElement, maxSwipes: Int = 8) {
        XCTAssertTrue(
            revealElement(element, in: settingsForm(), direction: .up, maxSwipes: maxSwipes),
            "Could not reveal '\(element.label)' in Settings"
        )
    }

    // MARK: - Settings (from SettingsUITests)

    private func verifySettingsPageContent() {
        openSettings()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings nav bar not found")

        let aboutHeader = app.staticTexts["About"]
        revealInSettings(aboutHeader, maxSwipes: 8)

        let sortDirection = app.staticTexts["Sort Direction"]
        revealInSettings(sortDirection, maxSwipes: 5)

        let supportLink = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == 'Contact Support' OR label == 'Report a Bug' OR label == 'Source Code'"
        )).firstMatch
        revealInSettings(supportLink, maxSwipes: 4)

        let tipJarHeader = app.staticTexts["Tip Jar"]
        revealInSettings(tipJarHeader, maxSwipes: 6)

        // Go back from Settings
        if let backButton = navigationBackButton() {
            backButton.tap()
        }
    }

    private func verifyTipJarContent() {
        openSettings()

        let tipJarHeader = app.staticTexts["Tip Jar"]
        revealInSettings(tipJarHeader, maxSwipes: 8)

        let smallTip = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Small' OR label CONTAINS[c] '$1.99' OR label CONTAINS[c] 'tip'")).firstMatch
        let notAvailable = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'not available' OR label CONTAINS[c] 'unavailable'")).firstMatch
        let hasTipContent = revealElement(smallTip, in: settingsForm(), direction: .up, maxSwipes: 2)
            || revealElement(notAvailable, in: settingsForm(), direction: .up, maxSwipes: 2)
        XCTAssertTrue(hasTipContent, "Tip Jar should show tip buttons or 'not available' fallback")

        let description = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] 'support' OR label CONTAINS[c] 'tip' OR label CONTAINS[c] 'free'"
        )).firstMatch
        revealInSettings(description, maxSwipes: 2)

        // Go back from Settings
        if let backButton = navigationBackButton() {
            backButton.tap()
        }
    }

    // MARK: - Helpers

    private func navigationBackButton() -> XCUIElement? {
        let toolbarIdentifiers = Set(["lock.button", "settings.button", "sort.menu", "Done"])

        return app.navigationBars.buttons.allElementsBoundByIndex.first { button in
            guard button.exists && button.isHittable else { return false }

            let identifier = button.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = button.label.trimmingCharacters(in: .whitespacesAndNewlines)

            if toolbarIdentifiers.contains(identifier) || toolbarIdentifiers.contains(label) {
                return false
            }

            return true
        }
    }

    private func navigateBackToRoot() {
        for _ in 0..<5 {
            if let backButton = navigationBackButton() {
                backButton.tap()
                sleep(1)
            } else {
                break
            }
        }
    }
}
