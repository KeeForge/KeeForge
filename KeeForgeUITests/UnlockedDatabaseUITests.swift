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
    /// The Security settings screen has no dedicated screen-capture-block
    /// toggle on iOS — that setting is macOS-only (`SettingsService.
    /// blockScreenCapture`'s doc comment: "iOS ignores it (iOS uses
    /// `UIScreen.isCaptured` shielding)", unconditionally, with no user
    /// facing switch). "Lock When App Goes to Background" is the closest
    /// real protective toggle on the iOS Security screen — locking the vault
    /// whenever the app leaves the foreground is itself a screen-protection
    /// behavior — so this test scopes to it instead of inventing a feature.
    func testSecuritySettingsShowsLockOnBackgroundToggleAndPersistsAcrossReopen() {
        openAppSettings()

        let securityLink = app.descendants(matching: .any).matching(identifier: "settings.security.link").firstMatch
        revealInSettings(securityLink, maxSwipes: 2)
        tapElement(securityLink)

        let lockOnBackgroundToggle = app.switches["settings.security.lock-on-background-toggle"]
        XCTAssertTrue(
            lockOnBackgroundToggle.waitForExistence(timeout: 5),
            "Security settings should expose the Lock When App Goes to Background toggle"
        )

        let originalValue = lockOnBackgroundToggle.value as? String
        let flippedValue = originalValue != "1"
        setSwitch(lockOnBackgroundToggle, isOn: flippedValue)

        returnToSettingsRoot()
        closeSettings()

        // Reopen Settings → Security and confirm the flipped value round-trips
        // through SettingsService (backed by UserDefaults, so it persists
        // across reopening the sheet without needing a relaunch).
        openAppSettings()
        let reopenedSecurityLink = app.descendants(matching: .any).matching(identifier: "settings.security.link").firstMatch
        revealInSettings(reopenedSecurityLink, maxSwipes: 2)
        tapElement(reopenedSecurityLink)

        let reopenedToggle = app.switches["settings.security.lock-on-background-toggle"]
        XCTAssertTrue(
            reopenedToggle.waitForExistence(timeout: 5),
            "Lock When App Goes to Background toggle should render after reopening Settings"
        )
        XCTAssertEqual(
            reopenedToggle.value as? String,
            flippedValue ? "1" : "0",
            "Lock When App Goes to Background should persist its flipped value after reopening the settings sheet"
        )

        // Restore the seeded default: SettingsService persists to
        // UserDefaults.standard (not the per-launch fixture registry), so an
        // unrestored flip would leak into later test runs on this simulator.
        setSwitch(reopenedToggle, isOn: originalValue == "1")
        returnToSettingsRoot()
        closeSettings()
    }

    /// Taps the "Settings" back button to return from a pushed settings
    /// subview (e.g. Security, AutoFill, Display) to the Settings root list.
    private func returnToSettingsRoot(file: StaticString = #filePath, line: UInt = #line) {
        let backButton = app.navigationBars.buttons["Settings"].firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "Back to Settings button was not visible", file: file, line: line)
        tapElement(backButton)
    }

    func testDisplaySettingsPageShowsUsageStatsToggle() {
        openAppSettings()

        let displayLink = app.descendants(matching: .any).matching(identifier: "settings.display.link").firstMatch
        revealInSettings(displayLink, maxSwipes: 2)
        tapElement(displayLink)

        let usageStatsToggle = app.switches["settings.display.usage-stats-toggle"]
        XCTAssertTrue(usageStatsToggle.waitForExistence(timeout: 5), "Display settings should expose the database list usage-stats toggle")
    }

    func testAutoFillSettingsListsDatabaseTogglesAndCancelableClear() {
        openAppSettings()

        let autoFillLink = app.descendants(matching: .any).matching(identifier: "settings.autofill.link").firstMatch
        revealInSettings(autoFillLink, maxSwipes: 2)
        tapElement(autoFillLink)

        // The suffix is the database's UUID, unknown to the test, so match on
        // the identifier prefix and require at least one per-database toggle
        // for the seeded fixture.
        let databaseToggles = app.switches.matching(
            NSPredicate(format: "identifier BEGINSWITH 'settings.autofill.database-toggle.'")
        )
        XCTAssertTrue(
            databaseToggles.firstMatch.waitForExistence(timeout: Self.ciElementTimeout),
            "AutoFill settings should list a toggle for the seeded database"
        )

        let clearButton = app.buttons["settings.autofill.clear-entries"]
        revealInSettings(clearButton)
        tapElement(clearButton)

        // SwiftUI exposes the confirmation action as two nested buttons that
        // both carry the identifier, so resolve with firstMatch.
        let confirmButton = app.buttons["settings.autofill.clear-entries.confirm"].firstMatch
        XCTAssertTrue(
            confirmButton.waitForExistence(timeout: 5),
            "Clear AutoFill Entries confirmation did not appear"
        )
        XCTAssertEqual(confirmButton.label, "Clear Entries")

        cancelConfirmationDialog()

        let dismissDeadline = Date().addingTimeInterval(10)
        while confirmButton.exists, Date() < dismissDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(confirmButton.exists, "Confirmation should dismiss after Cancel")
        XCTAssertTrue(
            clearButton.waitForExistence(timeout: 5),
            "Clear AutoFill Entries button should remain after canceling"
        )
    }

    /// Cancels the currently presented confirmation dialog. Older iOS
    /// versions render `confirmationDialog` as an action sheet with an
    /// explicit Cancel button; iOS 26 renders it as a popover whose only
    /// button is the destructive action, and canceling means tapping the
    /// system "dismiss popup" region outside the popover.
    private func cancelConfirmationDialog(file: StaticString = #filePath, line: UInt = #line) {
        let cancelButton = app.buttons["Cancel"].firstMatch
        if cancelButton.waitForExistence(timeout: 2) {
            tapElement(cancelButton)
            return
        }

        let dismissRegion = app.otherElements["PopoverDismissRegion"].firstMatch
        XCTAssertTrue(
            dismissRegion.waitForExistence(timeout: 5),
            "Neither a Cancel button nor a popover dismiss region was visible",
            file: file,
            line: line
        )

        // Tap a point inside the dismiss region but outside the popover
        // itself (a center tap can land on the popover, which sits on top).
        let windowFrame = app.windows.firstMatch.frame
        let popoverFrame = app.popovers.firstMatch.exists ? app.popovers.firstMatch.frame : .zero
        let targetY: CGFloat = popoverFrame.minY - windowFrame.minY > 60
            ? popoverFrame.minY - 30
            : min(popoverFrame.maxY + 30, windowFrame.maxY - 10)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: windowFrame.midX, dy: targetY))
            .tap()
    }

    func testSettingsPageShowsSupportAndAboutSections() {
        openAppSettings()

        let supportButton = app.buttons["settings.send-feedback"]
        revealInSettings(supportButton, maxSwipes: 4)

        let aboutLink = app.descendants(matching: .any).matching(identifier: "settings.about.link").firstMatch
        revealInSettings(aboutLink, maxSwipes: 4)
        tapElement(aboutLink)

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

// Coverage for changing a group's icon from the group context menu.
@MainActor
final class GroupIconPickerUITests: UnlockedDatabaseUITestCase {
    /// Round-trips the choice: pick an icon, then reopen the picker and confirm that
    /// cell now reports itself as selected. That only holds if the edit reached the
    /// group in the draft and was read back out again, so it covers the wiring the
    /// unit tests cannot see.
    func testChangingAGroupIconMarksTheNewIconAsSelected() {
        unlockSuccessfully()

        openIconPicker(forGroupNamed: "Social")

        let bankingIcon = app.buttons["group-icon-picker.icon.37"]
        XCTAssertTrue(bankingIcon.waitForExistence(timeout: 5), "Icon picker did not present")
        XCTAssertFalse(bankingIcon.isSelected, "Fixture group should not already use icon 37")
        tapElement(bankingIcon)

        XCTAssertTrue(
            bankingIcon.waitForNonExistence(timeout: 5),
            "Picking an icon should dismiss the picker"
        )

        openIconPicker(forGroupNamed: "Social")
        let reopenedIcon = app.buttons["group-icon-picker.icon.37"]
        XCTAssertTrue(reopenedIcon.waitForExistence(timeout: 5), "Icon picker did not present again")
        XCTAssertTrue(reopenedIcon.isSelected, "The chosen icon should come back marked as selected")
    }

    func testCancellingTheIconPickerLeavesTheIconAlone() {
        unlockSuccessfully()

        openIconPicker(forGroupNamed: "Social")
        let otherIcon = app.buttons["group-icon-picker.icon.37"]
        XCTAssertTrue(otherIcon.waitForExistence(timeout: 5), "Icon picker did not present")
        XCTAssertFalse(otherIcon.isSelected, "Fixture group should not already use icon 37")

        let cancelButton = app.buttons["group-icon-picker.cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Cancel button was not visible")
        tapElement(cancelButton)

        openIconPicker(forGroupNamed: "Social")
        let reopenedIcon = app.buttons["group-icon-picker.icon.37"]
        XCTAssertTrue(reopenedIcon.waitForExistence(timeout: 5), "Icon picker did not present again")
        XCTAssertFalse(reopenedIcon.isSelected, "Cancelling must not change the group's icon")
    }

    private func openIconPicker(
        forGroupNamed name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let group = groupRow(named: name)
        XCTAssertTrue(revealElement(group), "Group '\(name)' was not visible", file: file, line: line)
        group.press(forDuration: 1.0)

        let changeIcon = app.buttons["group-row.change-icon-context"]
        XCTAssertTrue(
            changeIcon.waitForExistence(timeout: 5),
            "Change Icon was not in the group context menu",
            file: file,
            line: line
        )
        tapElement(changeIcon)
    }
}

final class EntryHistoryUITests: UnlockedDatabaseUITestCase {
    func testEntryHistoryListsEarlierVersions() {
        unlockSuccessfully()
        openFixtureEntry()

        let historyRow = app.buttons["entry-detail.history"]
        guard revealElement(historyRow, in: scrollableContainer(), direction: .up, maxSwipes: 6) else {
            XCTFail("The fixture entry exposes no history row")
            return
        }
        tapElement(historyRow)

        let firstVersion = app.buttons["entry-history.version.0"]
        XCTAssertTrue(firstVersion.waitForExistence(timeout: 5), "History sheet showed no versions")

        app.buttons["entry-history.done"].tap()
    }

    func testOpeningAnEarlierVersionOffersRestore() {
        unlockSuccessfully()
        openFixtureEntry()

        let historyRow = app.buttons["entry-detail.history"]
        guard revealElement(historyRow, in: scrollableContainer(), direction: .up, maxSwipes: 6) else {
            XCTFail("The fixture entry exposes no history row")
            return
        }
        tapElement(historyRow)

        let firstVersion = app.buttons["entry-history.version.0"]
        XCTAssertTrue(firstVersion.waitForExistence(timeout: 5))
        firstVersion.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["entry-history.version-detail"].firstMatch
                .waitForExistence(timeout: 5),
            "The version screen did not open"
        )
        XCTAssertTrue(
            app.buttons["entry-history.restore"].waitForExistence(timeout: 5),
            "Restore action was not offered"
        )
    }

    func testRestoringAnEarlierVersionUpdatesTheEntry() {
        unlockSuccessfully()
        openFixtureEntry()

        let historyRow = app.buttons["entry-detail.history"]
        guard revealElement(historyRow, in: scrollableContainer(), direction: .up, maxSwipes: 6) else {
            XCTFail("The fixture entry exposes no history row")
            return
        }
        let versionCountBefore = historyRow.staticTexts.allElementsBoundByIndex.compactMap { Int($0.label) }.first
        tapElement(historyRow)

        app.buttons["entry-history.version.0"].tap()
        let restore = app.buttons["entry-history.restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.tap()

        // Confirm. The dialog is an action sheet on iPhone and a popover on iPad, and
        // the toolbar action carries the same label, so this addresses the confirmation
        // button by its own identifier rather than by label or position.
        // `.firstMatch`: SwiftUI propagates the identifier onto the button's inner
        // elements, so the plain query is ambiguous.
        let confirm = app.buttons["entry-history.restore.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Restore confirmation was not shown")
        confirm.tap()

        XCTAssertTrue(
            app.buttons["entry-detail.history"].waitForExistence(timeout: 10),
            "Restoring should return to the entry detail"
        )

        // The replaced state is kept, so the entry now has one more version than before.
        if let versionCountBefore {
            let after = app.buttons["entry-detail.history"].staticTexts
                .allElementsBoundByIndex.compactMap { Int($0.label) }.first
            XCTAssertEqual(after, versionCountBefore + 1, "the replaced state must be kept as a version")
        }
    }
}
