import XCTest

// End-to-end coverage for "Merge Changes" on a save conflict. The conflicting
// file is real: `UI_TEST_LOCAL_SAVE_CONFLICT_COUNT` makes the saver rewrite the
// database on disk with an extra "UI Test Conflict <n>" entry before it checks
// the hash, so the conflict, the divergent remote, and the merge that combines
// it with the local edit are all genuine.
@MainActor
class SaveConflictMergeUITestCase: EntryEditUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        // Exactly one: the merge's own write must reach the file it reconciled
        // against, not a freshly injected third version.
        app.launchEnvironment["UI_TEST_LOCAL_SAVE_CONFLICT_COUNT"] = "1"
    }

    /// Pops back until the top-level group list is showing. The unsaved-changes
    /// banner is a `safeAreaInset` on the navigation stack's root, so it is only
    /// observable there.
    ///
    /// A successful merge rebuilds the tree and can land back on the root by
    /// itself, so this waits for the root list before each pop and treats "no
    /// back button" as already-there rather than a failure — unlike
    /// `tapBackButton`, which fails the test outright.
    func returnToRootGroupList(
        anchorGroupName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let anchor = group(named: anchorGroupName)
        for _ in 0..<4 {
            if anchor.waitForExistence(timeout: 5) { return }
            if popNavigationStackIfPossible() == false { break }
        }
        // The root list is long enough that the anchor group can sit below the
        // fold, and a lazy List does not publish rows it has not drawn — so
        // scroll for it instead of only waiting for it to exist.
        XCTAssertTrue(
            revealElement(anchor),
            "Did not get back to the root group list: '\(anchorGroupName)' never appeared",
            file: file,
            line: line
        )
    }

    /// Backs out of an editor that is deliberately still open, to reach the
    /// vault behind it. Discarding drops only the editor's form state — the
    /// edit itself was applied to the draft before the save was attempted, so
    /// the unsaved draft survives.
    func closeEntryEditor(file: StaticString = #filePath, line: UInt = #line) {
        let cancelButton = app.buttons["entry-edit.cancel"]
        XCTAssertTrue(
            cancelButton.waitForExistence(timeout: 5),
            "Entry editor was not open to close",
            file: file,
            line: line
        )
        cancelButton.tap()

        let discardButton = app.alerts["Discard changes?"].buttons["Discard Changes"]
        if discardButton.waitForExistence(timeout: 3) {
            discardButton.tap()
        }
        XCTAssertTrue(
            waitForElementToDisappear(cancelButton, timeout: Self.ciElementTimeout),
            "Entry editor did not close",
            file: file,
            line: line
        )
    }

    /// Taps the current screen's back button, reporting whether there was one.
    private func popNavigationStackIfPossible() -> Bool {
        let excludedIdentifiers: Set<String> = [
            "entry-list.add-entry",
            "lock.button",
            "sort.menu",
            "settings.button",
            "entry-detail.edit",
            "entry-edit.cancel",
            "entry-edit.save",
        ]
        let excludedLabels: Set<String> = ["Edit", "Cancel", "Save"]

        for navigationBar in app.navigationBars.allElementsBoundByIndex
        where navigationBar.exists && navigationBar.isHittable {
            guard let backButton = navigationBar.buttons.allElementsBoundByIndex.first(where: {
                $0.exists
                    && $0.isHittable
                    && excludedIdentifiers.contains($0.identifier) == false
                    && excludedLabels.contains($0.label) == false
            }) else { continue }
            backButton.tap()
            return true
        }
        return false
    }
}

@MainActor
final class SaveConflictMergeUITests: SaveConflictMergeUITestCase {
    private let mergedDiscordTitle = "Discord Merged Locally"
    /// Injected into the visible root group of the conflicting copy — the hook
    /// mirrors `DatabaseViewModel.visibleRootGroupID`'s wrapper-skipping rule.
    private let remoteOnlyEntryTitle = "UI Test Conflict 1"

    func testMergeCombinesRemoteEntryWithLocalEditAndSaves() {
        unlockSuccessfully()

        openEntry(named: discordEntryTitle, inGroup: socialGroupName)
        editCurrentEntryTitle(to: mergedDiscordTitle)
        XCTAssertTrue(waitForSaveConflictAlert(), "Save conflict alert did not appear")

        let mergeButton = app.buttons["save-conflict.merge"].firstMatch
        XCTAssertTrue(mergeButton.waitForExistence(timeout: 5), "Merge Changes was not offered")
        mergeButton.tap()

        let mergeSummaryOK = app.buttons["merge-summary.ok"].firstMatch
        XCTAssertTrue(
            mergeSummaryOK.waitForExistence(timeout: Self.ciElementTimeout),
            "Changes Merged confirmation did not appear"
        )

        let summaryAlert = app.alerts["Changes Merged"]
        XCTAssertTrue(summaryAlert.exists, "Merge confirmation was not the Changes Merged alert")
        let summaryText = summaryAlert.staticTexts.allElementsBoundByIndex
            .map(\.label)
            .joined(separator: "\n")
        XCTAssertTrue(
            summaryText.contains("combined with yours and saved"),
            "Expected the counted-changes summary, got: \(summaryText)"
        )
        XCTAssertFalse(
            summaryText.contains("no new changes"),
            "Merged nothing — the conflicting copy was not actually divergent: \(summaryText)"
        )

        mergeSummaryOK.tap()
        XCTAssertTrue(
            waitForElementToDisappear(mergeSummaryOK, timeout: 5),
            "Changes Merged alert did not dismiss"
        )

        // The merge persisted this editor's edit, so the editor closes itself —
        // a conflicted save only holds it open until the conflict resolves.
        XCTAssertTrue(
            waitForElementToDisappear(app.buttons["entry-edit.save"], timeout: Self.ciElementTimeout),
            "Entry editor stayed open after the merge saved its edit"
        )

        returnToRootGroupList(anchorGroupName: socialGroupName)

        // The remote-only record survived the merge...
        XCTAssertTrue(
            revealElement(entry(named: remoteOnlyEntryTitle)),
            "Entry added by the other copy is missing after the merge"
        )
        // ...and so did the local edit that caused the conflict.
        XCTAssertFalse(
            waitForUnsavedIndicator(isPresent: true, timeout: 3),
            "Unsaved-changes banner is still up after a successful merge save"
        )

        openGroup(named: socialGroupName)
        XCTAssertTrue(
            revealElement(entry(named: mergedDiscordTitle)),
            "Local edit is missing after the merge"
        )
    }
}

// The conflicting copy grows an extra binary-pool field, which the merger
// refuses to reconcile because entries in this fixture point into the pool.
@MainActor
final class SaveConflictMergeDeclineUITests: SaveConflictMergeUITestCase {
    override var databaseFixtureName: String { "kitchen-sink" }

    private let attachmentsGroupName = "Attachments"
    private let plainEntryTitle = "No Attachment Entry"
    private let editedPlainEntryTitle = "No Attachment Entry Edited"

    override func configureLaunch(app: XCUIApplication) throws {
        try super.configureLaunch(app: app)
        app.launchEnvironment["UI_TEST_LOCAL_SAVE_CONFLICT_DIVERGES_POOL"] = "1"
    }

    func testMergeDeclinedForDivergedAttachmentsKeepsDraftAndConflictOptions() {
        unlockSuccessfully()

        openEntry(named: plainEntryTitle, inGroup: attachmentsGroupName)
        editCurrentEntryTitle(to: editedPlainEntryTitle)
        XCTAssertTrue(waitForSaveConflictAlert(), "Save conflict alert did not appear")

        let mergeButton = app.buttons["save-conflict.merge"].firstMatch
        XCTAssertTrue(mergeButton.waitForExistence(timeout: 5), "Merge Changes was not offered")
        mergeButton.tap()

        let failureOK = app.buttons["merge-failure.ok"].firstMatch
        XCTAssertTrue(
            failureOK.waitForExistence(timeout: Self.ciElementTimeout),
            "Couldn't Merge Changes alert did not appear"
        )
        let failureAlert = app.alerts.containing(.button, identifier: "merge-failure.ok").firstMatch
        XCTAssertTrue(failureAlert.exists, "Merge failure was not reported by its own alert")
        let failureText = failureAlert.staticTexts.allElementsBoundByIndex
            .map(\.label)
            .joined(separator: "\n")
        XCTAssertTrue(
            failureText.contains("Merge Changes"),
            "Merge failure alert was not the Couldn't Merge Changes alert: \(failureText)"
        )
        XCTAssertTrue(
            failureText.contains("attachments"),
            "Merge failure did not explain the attachment-pool divergence: \(failureText)"
        )
        failureOK.tap()

        // Acknowledging a declined merge is not a dead end: the conflict alert
        // comes back with the remaining options.
        XCTAssertTrue(
            waitForSaveConflictAlert(timeout: Self.ciElementTimeout),
            "Save conflict alert did not come back after acknowledging the failed merge"
        )
        let cancelButton = app.buttons["save-conflict.cancel"].firstMatch
        XCTAssertTrue(app.buttons["save-conflict.reload"].firstMatch.exists)
        XCTAssertTrue(app.buttons["save-conflict.save-as-copy"].firstMatch.exists)
        cancelButton.tap()
        XCTAssertTrue(waitForElementToDisappear(cancelButton, timeout: 5), "Conflict alert did not dismiss")

        // Nothing was written, so the editor is still up on its unsaved edit and
        // the user can retry Save or back out.
        XCTAssertTrue(
            app.navigationBars["Edit Entry"].waitForExistence(timeout: 5),
            "Entry editor should stay open while the conflict is unresolved"
        )
        XCTAssertTrue(app.buttons["entry-edit.save"].exists, "Editor lost its Save action")

        closeEntryEditor()
        returnToRootGroupList(anchorGroupName: attachmentsGroupName)
        XCTAssertTrue(
            waitForUnsavedIndicator(isPresent: true, timeout: Self.ciElementTimeout),
            "Declining the merge should leave the unsaved draft — and its banner — in place"
        )

        openGroup(named: attachmentsGroupName)
        XCTAssertTrue(
            revealElement(entry(named: editedPlainEntryTitle)),
            "The unsaved local edit was lost after the merge was declined"
        )
    }
}
