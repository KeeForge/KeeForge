import XCTest

@MainActor
final class AutoLockActivityUITests: EntryEditUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        try super.configureLaunch(app: app)
        app.launchArguments += ["-KeeForge.autoLockTimeout", "30 Seconds", "-KeeForge.lockOnBackground", "NO"]
    }

    func testTypingNotesKeepsEditorOpenThenIdlenessRequestsLock() {
        openEditor()
        let notes = app.textViews["entry-edit.notes-field"]
        XCTAssertTrue(revealElement(notes))
        replaceText(in: notes, with: "Activity")

        performActivityPastTimeout {
            notes.typeText("x")
        }

        XCTAssertTrue(
            app.alerts["Save your changes before locking?"].waitForExistence(timeout: 35),
            "Stopping typing must still request a lock without losing the unsaved notes"
        )
    }

    func testScrollingKeepsEditorOpenThenIdlenessLocks() {
        openEditor()
        performActivityPastTimeout {
            app.swipeUp()
            app.swipeDown()
        }
        XCTAssertTrue(waitForLockedState(timeout: 35), "The clean editor must lock once scrolling stops")
    }

    func testButtonsKeepEditorOpenThenIdlenessLocks() {
        openEditor()
        let visibility = app.buttons["entry-edit.password-visibility-button"]
        XCTAssertTrue(revealElement(visibility))
        performActivityPastTimeout {
            visibility.tap()
        }
        XCTAssertTrue(waitForLockedState(timeout: 35), "The clean editor must lock once button taps stop")
    }

    private func openEditor() {
        unlockSuccessfully()
        tapAddEntry()
        XCTAssertTrue(app.buttons["entry-edit.cancel"].waitForExistence(timeout: 5))
    }

    private func performActivityPastTimeout(_ action: () -> Void) {
        let deadline = Date().addingTimeInterval(35)
        repeat {
            guard app.buttons["entry-edit.cancel"].exists,
                  app.alerts["Save your changes before locking?"].exists == false else {
                XCTFail("The database requested a lock during active use")
                return
            }
            action()
        } while Date() < deadline
        XCTAssertTrue(app.buttons["entry-edit.cancel"].exists)
        XCTAssertFalse(app.alerts["Save your changes before locking?"].exists)
    }
}
