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

@MainActor
class AppSettingsUITestCase: KeeForgeUITestCase {
    func openAppSettings(file: StaticString = #filePath, line: UInt = #line) {
        let settingsButton = app.buttons["database.settings.button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Database list settings button was not visible", file: file, line: line)
        tapElement(settingsButton)

        let doneButton = app.buttons["Done"].firstMatch
        let displayLink = app.descendants(matching: .any).matching(identifier: "settings.display.link").firstMatch
        XCTAssertTrue(
            doneButton.waitForExistence(timeout: 5) || displayLink.waitForExistence(timeout: 5),
            "Settings sheet did not appear",
            file: file,
            line: line
        )
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
        tapElement(doneButton)
    }

    private func activeSettingsContainer(file: StaticString, line: UInt) -> XCUIElement {
        if let container = scrollableContainer() {
            return container
        }

        XCTFail("No visible settings container was found", file: file, line: line)
        return app.collectionViews.firstMatch
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

// Secondary, non-gating coverage for root app settings surfaces.
@MainActor
final class AppSettingsUITests: AppSettingsUITestCase {
    func testDisplaySettingsPageShowsUsageStatsToggle() {
        openAppSettings()

        let displayLink = app.descendants(matching: .any).matching(identifier: "settings.display.link").firstMatch
        revealInSettings(displayLink, maxSwipes: 2)
        tapElement(displayLink)

        let usageStatsToggle = app.switches["settings.display.usage-stats-toggle"]
        XCTAssertTrue(usageStatsToggle.waitForExistence(timeout: 5), "Display settings should expose the database list usage-stats toggle")
    }

    func testSettingsPageShowsSupportAndAboutSections() {
        openAppSettings()

        let aboutLink = app.descendants(matching: .any).matching(identifier: "settings.about.link").firstMatch
        revealInSettings(aboutLink, maxSwipes: 2)
        tapElement(aboutLink)

        let supportButton = app.buttons["settings.send-feedback"]
        revealInSettings(supportButton, maxSwipes: 4)

        let sourceCodeLink = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Source Code'")
        ).firstMatch
        revealInSettings(sourceCodeLink, maxSwipes: 4)

        let backToSettingsButton = app.navigationBars.buttons["Settings"].firstMatch
        if backToSettingsButton.waitForExistence(timeout: 2) {
            tapElement(backToSettingsButton)
        }

        closeSettings()
    }

    func testTipJarSectionShowsProductsOrFallback() {
        openAppSettings()

        let tipJarHeader = app.staticTexts["Tip Jar"]
        revealInSettings(tipJarHeader, maxSwipes: 6)

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
