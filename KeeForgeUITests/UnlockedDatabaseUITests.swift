import XCTest

@MainActor
class UnlockedDatabaseUITestCase: KeeForgeUITestCase {
    func openFixtureEntry(
        groupName: String = "Social",
        entryName: String = "Twitter",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        openGroup(named: groupName, file: file, line: line)
        openEntry(named: entryName, file: file, line: line)
    }

    func openGroup(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        let group = groupRow(named: name)
        XCTAssertTrue(revealElement(group), "Group '\(name)' was not visible", file: file, line: line)
        tapElement(group)
    }

    func openEntry(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        let entry = entryRow(named: name)
        XCTAssertTrue(revealElement(entry), "Entry '\(name)' was not visible", file: file, line: line)
        tapElement(entry)
    }

    func groupRow(named name: String) -> XCUIElement {
        firstRowMatching(name: name, preferredIdentifier: "group.navlink")
    }

    func entryRow(named name: String) -> XCUIElement {
        firstRowMatching(name: name, preferredIdentifier: "entry.navlink")
    }

    func activateSearchField(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let searchField = app.searchFields["Search entries"].firstMatch
        if searchField.waitForExistence(timeout: 1) == false, let container = scrollableContainer() {
            container.swipeDown()
        }

        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Search field was not visible", file: file, line: line)
        if searchField.isHittable == false {
            _ = revealElement(searchField, in: scrollableContainer(), direction: .down, maxSwipes: 2)
        }
        tapElement(searchField)
        return searchField
    }

    func clearSearchField(_ searchField: XCUIElement) {
        let clearButton = searchField.buttons["Clear text"]
        if clearButton.exists {
            clearButton.tap()
            return
        }

        let currentValue = (searchField.value as? String) ?? ""
        guard currentValue.isEmpty == false, currentValue != "Search entries" else {
            return
        }

        let deleteSequence = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
        searchField.typeText(deleteSequence)
    }

    func searchResult(named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier IN %@ AND label CONTAINS[c] %@",
                ["entry.navlink", "search.entry.navlink"],
                name
            )
        ).firstMatch
    }

    func openAppSettings(file: StaticString = #filePath, line: UInt = #line) {
        let settingsButton = app.buttons["settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button was not visible", file: file, line: line)
        settingsButton.tap()

        let databaseSettingsBar = app.navigationBars["Database Settings"]
        XCTAssertTrue(
            databaseSettingsBar.waitForExistence(timeout: 5),
            "Database Settings sheet did not appear",
            file: file,
            line: line
        )

        let appSettingsButton = app.buttons["App Settings"]
        XCTAssertTrue(
            revealElement(appSettingsButton, in: activeSettingsContainer(file: file, line: line), direction: .up, maxSwipes: 6),
            "App Settings button was not visible in Database Settings",
            file: file,
            line: line
        )
        appSettingsButton.tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings sheet did not appear", file: file, line: line)
    }

    func revealInSettings(
        _ element: XCUIElement,
        maxSwipes: Int = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            revealElement(element, in: activeSettingsContainer(file: file, line: line), direction: .up, maxSwipes: maxSwipes),
            "Could not reveal '\(element.label)' in Settings",
            file: file,
            line: line
        )
    }

    func closeSettings(file: StaticString = #filePath, line: UInt = #line) {
        let doneButton = app.navigationBars["Settings"].buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "Done button was not visible", file: file, line: line)
        doneButton.tap()

        let closeButton = app.navigationBars["Database Settings"].buttons["Close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Close button was not visible", file: file, line: line)
        closeButton.tap()
    }

    private func activeSettingsContainer(file: StaticString, line: UInt) -> XCUIElement {
        if let container = scrollableContainer() {
            return container
        }

        XCTFail("No visible settings container was found", file: file, line: line)
        return app.collectionViews.firstMatch
    }

    private func firstRowMatching(name: String, preferredIdentifier: String) -> XCUIElement {
        let preferredQuery = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS[c] %@", preferredIdentifier, name)
        )
        let labelPredicate = NSPredicate(format: "label CONTAINS[c] %@", name)
        let buttonQuery = app.buttons.matching(labelPredicate)
        let cellQuery = app.cells.matching(labelPredicate)

        let candidates = preferredQuery.allElementsBoundByIndex + buttonQuery.allElementsBoundByIndex + cellQuery.allElementsBoundByIndex
        return candidates.first(where: { $0.exists && $0.isHittable })
            ?? candidates.first(where: { $0.exists })
            ?? preferredQuery.firstMatch
    }
}

// Happy-path smoke coverage for unlocked browsing and detail screens.
@MainActor
final class UnlockedDatabaseBrowseAndDetailUITests: UnlockedDatabaseUITestCase {
    func testFixtureGroupShowsExpectedEntry() {
        unlockSuccessfully()

        openGroup(named: "Social")

        let twitterEntry = entryRow(named: "Twitter")
        XCTAssertTrue(revealElement(twitterEntry), "Twitter entry was not visible in Social")
    }

    func testFixtureEntryDetailShowsCopyActions() {
        unlockSuccessfully()

        openFixtureEntry()

        let passwordCopy = app.buttons["entry.copy.password"]
        let urlCopy = app.buttons["entry.copy.url"]
        XCTAssertTrue(passwordCopy.waitForExistence(timeout: 5), "Password copy action was not visible")
        XCTAssertTrue(urlCopy.waitForExistence(timeout: 5), "URL copy action was not visible")

        passwordCopy.tap()
        urlCopy.tap()
    }

    func testFixtureEntryDetailShowsTimestamps() {
        unlockSuccessfully()

        openFixtureEntry()

        let createdLabel = app.staticTexts["Created"]
        let modifiedLabel = app.staticTexts["Modified"]
        let container = scrollableContainer()
        let foundCreated = revealElement(createdLabel, in: container, direction: .up, maxSwipes: 4)
        let foundModified = revealElement(modifiedLabel, in: container, direction: .up, maxSwipes: 4)

        XCTAssertTrue(foundCreated || foundModified, "Entry detail should show Created or Modified timestamps")
    }
}

// Happy-path smoke coverage for unlocked search and sorting flows.
@MainActor
final class UnlockedDatabaseSearchAndSortUITests: UnlockedDatabaseUITestCase {
    func testSearchFieldStaysVisibleWhileTypingFixtureQuery() {
        unlockSuccessfully()

        let searchField = activateSearchField()
        clearSearchField(searchField)
        searchField.typeText("Twi")

        let resultsCountLabel = app.staticTexts["search.results.count"]
        XCTAssertTrue(app.searchFields["Search entries"].waitForExistence(timeout: 2), "Search field disappeared while typing")
        XCTAssertTrue(resultsCountLabel.waitForExistence(timeout: 5), "Search results count did not appear")
        XCTAssertNotEqual(resultsCountLabel.label, "results:0", "Expected search results for 'Twi'")
        XCTAssertTrue(searchResult(named: "Twitter").waitForExistence(timeout: 5), "Expected Twitter to appear in search results")
    }

    func testSearchShowsFixtureMatchAndNoResultsState() {
        unlockSuccessfully()

        let searchField = activateSearchField()
        clearSearchField(searchField)
        searchField.typeText("Twitter")

        let resultsCountLabel = app.staticTexts["search.results.count"]
        XCTAssertTrue(resultsCountLabel.waitForExistence(timeout: 5), "Search results count did not appear")
        XCTAssertNotEqual(resultsCountLabel.label, "results:0", "Expected Twitter to appear in search results")
        XCTAssertTrue(searchResult(named: "Twitter").waitForExistence(timeout: 5), "Expected Twitter to appear in search results")

        tapElement(searchField)
        clearSearchField(searchField)
        searchField.typeText("___unlikely_query___")

        XCTAssertTrue(app.staticTexts["search.no-results"].waitForExistence(timeout: 5), "Expected no-results state for an unlikely query")
    }

    func testSortMenuShowsExpectedOptions() {
        unlockSuccessfully()

        let sortMenu = app.buttons["sort.menu"]
        XCTAssertTrue(sortMenu.waitForExistence(timeout: 5), "Sort menu button was not visible")
        sortMenu.tap()

        XCTAssertTrue(app.buttons["Title"].waitForExistence(timeout: 5), "Title sort option was not visible")
        XCTAssertTrue(app.buttons["Date Created"].exists, "Date Created sort option was not visible")
        XCTAssertTrue(app.buttons["Date Modified"].exists, "Date Modified sort option was not visible")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    }

    func testChangingSortOrderKeepsFixtureGroupsVisible() {
        unlockSuccessfully()

        let sortMenu = app.buttons["sort.menu"]
        XCTAssertTrue(sortMenu.waitForExistence(timeout: 5), "Sort menu button was not visible")
        sortMenu.tap()

        let modifiedOption = app.buttons["Date Modified"]
        XCTAssertTrue(modifiedOption.waitForExistence(timeout: 5), "Date Modified sort option was not visible")
        modifiedOption.tap()

        let socialGroup = groupRow(named: "Social")
        let workGroup = groupRow(named: "Work")
        XCTAssertTrue(
            revealElement(socialGroup) || revealElement(workGroup),
            "Expected fixture groups to remain visible after changing sort order"
        )
    }
}

// Happy-path smoke coverage for the regular-width workspace shell.
@MainActor
final class RegularWidthWorkspaceUITests: UnlockedDatabaseUITestCase {
    func testRegularWidthWorkspaceShowsPlaceholderThenSelectedEntryDetail() throws {
        try requireRegularWidthLayout()
        unlockSuccessfully()

        let identifiedPlaceholder = app.descendants(matching: .any).matching(
            identifier: "regular-workspace.select-entry-placeholder"
        ).firstMatch
        let titledPlaceholder = app.staticTexts["Select an Entry"]
        XCTAssertTrue(
            identifiedPlaceholder.waitForExistence(timeout: 2) || titledPlaceholder.waitForExistence(timeout: 5),
            "Regular-width workspace should show the Select an Entry placeholder before a detail is chosen"
        )

        openGroup(named: "Social")
        openEntry(named: "Twitter")

        let passwordCopy = app.buttons["entry.copy.password"]
        XCTAssertTrue(passwordCopy.waitForExistence(timeout: 5), "Selected entry detail should appear in the regular-width workspace")
    }
}

// Secondary, non-gating coverage for unlocked settings surfaces.
@MainActor
final class UnlockedDatabaseSettingsUITests: UnlockedDatabaseUITestCase {
    func testSettingsPageShowsSupportAndAboutSections() {
        unlockSuccessfully()

        openAppSettings()

        let supportButton = app.buttons["settings.send-feedback"]
        revealInSettings(supportButton, maxSwipes: 4)

        let aboutHeader = app.staticTexts["About"]
        revealInSettings(aboutHeader, maxSwipes: 8)

        let sourceCodeLink = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Source Code'")
        ).firstMatch
        revealInSettings(sourceCodeLink, maxSwipes: 4)

        closeSettings()
    }

    func testTipJarSectionShowsProductsOrFallback() {
        unlockSuccessfully()

        openAppSettings()

        let tipJarHeader = app.staticTexts["Tip Jar"]
        revealInSettings(tipJarHeader, maxSwipes: 8)

        let tipButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] '$' OR label CONTAINS[c] 'Small' OR label CONTAINS[c] 'tip'")
        ).firstMatch
        let unavailableText = app.staticTexts["Tip Jar is not available right now."]
        let deadline = Date().addingTimeInterval(10)
        var foundTipJarContent = false

        repeat {
            foundTipJarContent =
                revealElement(tipButton, in: scrollableContainer(), direction: .up, maxSwipes: 2)
                || revealElement(unavailableText, in: scrollableContainer(), direction: .up, maxSwipes: 2)

            if foundTipJarContent {
                break
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        XCTAssertTrue(foundTipJarContent, "Tip Jar should show products or the unavailable fallback")

        closeSettings()
    }
}
