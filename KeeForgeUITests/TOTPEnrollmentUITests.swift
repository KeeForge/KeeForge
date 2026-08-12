import XCTest

// Enrollment coverage for the entry editor's One-Time Password section and
// the incoming `otpauth://` destination sheet. Camera scanning cannot be
// driven by XCUITest (no simulator camera), and URI parsing is unit-tested
// (`OTPAuthURITests`, `EntryEditViewModelTests`,
// `TOTPEnrollmentViewModelTests`); these classes prove the UI wiring only.
@MainActor
class TOTPEnrollmentUITestCase: UnlockedDatabaseUITestCase {
    // `autofill-union.kdbx`'s "Union Bank" and "Union Shop" entries carry no
    // TOTP (only "Union News" does); shares `test.kdbx`'s password, which the
    // default `unlockSuccessfully()` uses. See `TestFixtures/README.md`.
    override var databaseFixtureName: String { "autofill-union" }

    func openEditor(file: StaticString = #filePath, line: UInt = #line) {
        let editButton = app.buttons["entry-detail.edit"]
        XCTAssertTrue(
            editButton.waitForExistence(timeout: 5),
            "Edit button was not visible",
            file: file,
            line: line
        )
        tapElement(editButton)
    }

    func assertDetailRendersCode(
        digits: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let totpCode = app.staticTexts["entry.totp.code"]
        XCTAssertTrue(
            revealElement(totpCode, in: scrollableContainer()),
            "TOTP code was not visible in entry detail",
            file: file,
            line: line
        )

        let code = totpCode.label
        XCTAssertEqual(
            code.count,
            digits,
            "Expected a \(digits)-digit TOTP code, got '\(code)'",
            file: file,
            line: line
        )
        XCTAssertTrue(
            code.allSatisfy(\.isNumber),
            "Expected TOTP code to be numeric, got '\(code)'",
            file: file,
            line: line
        )
    }

    func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists == false {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return element.exists == false
    }

    func saveEditorAndWaitForDismissal(file: StaticString = #filePath, line: UInt = #line) {
        let saveButton = app.buttons["entry-edit.save"]
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 5),
            "Entry editor save button was not visible",
            file: file,
            line: line
        )
        tapElement(saveButton)
        XCTAssertTrue(
            waitForDisappearance(of: saveButton),
            "Entry editor did not dismiss after save",
            file: file,
            line: line
        )
    }
}

// Editor-path enrollment: manual setup key, pasted setup link, and removal.
@MainActor
final class TOTPEnrollmentUITests: TOTPEnrollmentUITestCase {
    func testManualSetupKeyEnrollmentRendersCodeInDetail() {
        unlockSuccessfully()
        openFixtureEntry(groupName: "Union", entryName: "Union Bank")
        openEditor()

        let enterKeyButton = app.buttons["entry-edit.totp.enter-key"]
        XCTAssertTrue(
            revealElement(enterKeyButton, in: scrollableContainer()),
            "Enter Setup Key button was not visible"
        )
        tapElement(enterKeyButton)

        // Edit mode starts the secret concealed; reveal it so typing targets a
        // plain text field. The simulator has no passcode or enrolled
        // biometrics, so the device-owner gate falls through to a plain reveal.
        let visibilityButton = app.buttons["entry-edit.totp.secret-visibility-button"]
        XCTAssertTrue(
            revealElement(visibilityButton, in: scrollableContainer()),
            "TOTP secret visibility toggle was not visible"
        )
        tapElement(visibilityButton)

        let secretField = app.textFields["entry-edit.totp.secret-field"]
        XCTAssertTrue(
            revealElement(secretField, in: scrollableContainer()),
            "TOTP secret field was not visible"
        )
        replaceText(in: secretField, with: "JBSWY3DPEHPK3PXP")

        saveEditorAndWaitForDismissal()
        assertDetailRendersCode(digits: 6)
    }

    func testSetupLinkEnrollmentAppliesConfigurationAndRendersCode() {
        unlockSuccessfully()
        openFixtureEntry(groupName: "Union", entryName: "Union Shop")
        openEditor()

        let enterLinkButton = app.buttons["entry-edit.totp.enter-link"]
        XCTAssertTrue(
            revealElement(enterLinkButton, in: scrollableContainer()),
            "Enter Setup Link button was not visible"
        )
        tapElement(enterLinkButton)

        let linkField = app.textFields["entry-edit.totp.link-field"]
        XCTAssertTrue(linkField.waitForExistence(timeout: 5), "Setup link field was not visible")
        replaceText(
            in: linkField,
            with: "otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example&digits=8&period=45"
        )

        let applyButton = app.buttons["entry-edit.totp.link-apply"]
        XCTAssertTrue(applyButton.waitForExistence(timeout: 5), "Apply button was not visible")
        tapElement(applyButton)
        XCTAssertTrue(
            waitForDisappearance(of: linkField),
            "Setup link sheet did not dismiss after a valid link"
        )

        // The applied link's non-default configuration lands in the form.
        let periodField = app.textFields["entry-edit.totp.period-field"]
        XCTAssertTrue(
            revealElement(periodField, in: scrollableContainer()),
            "TOTP period field was not visible after applying the link"
        )
        XCTAssertEqual(
            periodField.value as? String,
            "45",
            "Applied setup link's period was not reflected in the form"
        )

        saveEditorAndWaitForDismissal()
        assertDetailRendersCode(digits: 8)
    }

    func testSetupLinkRejectsInvalidLinkInlineAndCancelLeavesEntryUnchanged() {
        unlockSuccessfully()
        openFixtureEntry(groupName: "Union", entryName: "Union Bank")
        openEditor()

        let enterLinkButton = app.buttons["entry-edit.totp.enter-link"]
        XCTAssertTrue(
            revealElement(enterLinkButton, in: scrollableContainer()),
            "Enter Setup Link button was not visible"
        )
        tapElement(enterLinkButton)

        let linkField = app.textFields["entry-edit.totp.link-field"]
        XCTAssertTrue(linkField.waitForExistence(timeout: 5), "Setup link field was not visible")
        replaceText(in: linkField, with: "https://example.com/not-a-setup-link")

        let applyButton = app.buttons["entry-edit.totp.link-apply"]
        XCTAssertTrue(applyButton.waitForExistence(timeout: 5), "Apply button was not visible")
        tapElement(applyButton)

        let inlineError = app.staticTexts["entry-edit.totp.link-error"]
        XCTAssertTrue(
            inlineError.waitForExistence(timeout: 5),
            "Invalid setup link did not surface the inline error"
        )
        XCTAssertTrue(linkField.exists, "Setup link sheet dismissed despite the invalid link")

        let cancelButton = app.buttons["entry-edit.totp.link-cancel"]
        tapElement(cancelButton)
        XCTAssertTrue(
            waitForDisappearance(of: linkField),
            "Setup link sheet did not dismiss on cancel"
        )

        // Nothing was applied: the entry paths are still offered and the
        // pristine editor cancels without a discard prompt.
        let enterKeyButton = app.buttons["entry-edit.totp.enter-key"]
        XCTAssertTrue(
            revealElement(enterKeyButton, in: scrollableContainer()),
            "TOTP entry paths were not offered after cancelling the link sheet"
        )
        let editorCancel = app.buttons["entry-edit.cancel"]
        tapElement(editorCancel)
        XCTAssertTrue(
            waitForDisappearance(of: editorCancel),
            "Editor did not dismiss cleanly after a cancelled link sheet"
        )
    }

    func testRemoveVerificationCodeClearsDetail() {
        unlockSuccessfully()
        openFixtureEntry(groupName: "Union", entryName: "Union News")
        assertDetailRendersCode(digits: 6)
        openEditor()

        let removeButton = app.buttons["entry-edit.totp.remove"]
        XCTAssertTrue(
            revealElement(removeButton, in: scrollableContainer()),
            "Remove Verification Code button was not visible"
        )
        tapElement(removeButton)

        let removeConfirm = app.buttons["entry-edit.totp.remove-confirm"].firstMatch
        XCTAssertTrue(
            removeConfirm.waitForExistence(timeout: 5),
            "Remove confirmation was not presented"
        )
        tapElement(removeConfirm)

        // The configuration rows give way to the entry paths again.
        let enterKeyButton = app.buttons["entry-edit.totp.enter-key"]
        XCTAssertTrue(
            revealElement(enterKeyButton, in: scrollableContainer()),
            "TOTP entry paths did not return after removal"
        )

        saveEditorAndWaitForDismissal()

        let editButton = app.buttons["entry-detail.edit"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5), "Entry detail was not visible after save")
        XCTAssertFalse(
            app.staticTexts["entry.totp.code"].exists,
            "TOTP code still rendered in entry detail after removal"
        )
    }
}

// Incoming `otpauth://` deep links: the destination sheet KeeForge presents
// when a setup link is opened from outside the app (Safari, the iOS
// "Set Up Codes In" integration). Driven with `XCUIDevice.shared.system.open`,
// which opens the registered scheme without a browser round-trip.
@MainActor
final class TOTPEnrollmentDeepLinkUITests: TOTPEnrollmentUITestCase {
    override func configureLaunch(app: XCUIApplication) throws {
        try super.configureLaunch(app: app)
        if name.contains("ReadOnly") {
            app.launchEnvironment["UI_TEST_DATABASE_READ_ONLY"] = "1"
        }
    }

    private func openOTPAuthURL(_ string: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let url = URL(string: string) else {
            XCTFail("Malformed test URL: \(string)", file: file, line: line)
            return
        }
        XCUIDevice.shared.system.open(url)
    }

    private func waitForDestinationSheet(file: StaticString = #filePath, line: UInt = #line) {
        let titleBar = app.navigationBars["Add Verification Code"]
        XCTAssertTrue(
            titleBar.waitForExistence(timeout: KeeForgeUITestCase.ciElementTimeout),
            "TOTP enrollment destination sheet did not appear",
            file: file,
            line: line
        )
    }

    private func enrollmentEntryRow(titled title: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'totp-enroll.entry.' AND label CONTAINS[c] %@",
                title
            )
        ).firstMatch
    }

    private func dismissDestinationSheet(file: StaticString = #filePath, line: UInt = #line) {
        let cancelButton = app.buttons["totp-enroll.cancel"]
        XCTAssertTrue(
            cancelButton.waitForExistence(timeout: 5),
            "Destination sheet cancel button was not visible",
            file: file,
            line: line
        )
        tapElement(cancelButton)
        XCTAssertTrue(
            waitForDisappearance(of: cancelButton),
            "Destination sheet did not dismiss on cancel",
            file: file,
            line: line
        )
    }

    func testDeepLinkAttachesCodeToExistingEntry() {
        unlockSuccessfully()

        openOTPAuthURL("otpauth://totp/UnionBank:teller@unionbank-fixture.net?secret=JBSWY3DPEHPK3PXP&issuer=UnionBank")
        waitForDestinationSheet()

        let bankRow = enrollmentEntryRow(titled: "Union Bank")
        XCTAssertTrue(
            revealElement(bankRow, in: scrollableContainer()),
            "Union Bank candidate row was not visible"
        )
        tapElement(bankRow)

        // No existing code on Union Bank, so the editor opens directly with
        // the link applied.
        saveEditorAndWaitForDismissal()

        openFixtureEntry(groupName: "Union", entryName: "Union Bank")
        assertDetailRendersCode(digits: 6)
    }

    func testDeepLinkAsksBeforeReplacingExistingCodeAndEditorCancelReturnsToSheet() {
        unlockSuccessfully()

        openOTPAuthURL("otpauth://totp/UnionNews:reader@union-news-fixture.org?secret=JBSWY3DPEHPK3PXP&issuer=UnionNews")
        waitForDestinationSheet()

        // Union News already carries a code, so picking it must confirm first.
        let newsRow = enrollmentEntryRow(titled: "Union News")
        XCTAssertTrue(
            revealElement(newsRow, in: scrollableContainer()),
            "Union News candidate row was not visible"
        )
        tapElement(newsRow)

        let replaceConfirm = app.buttons["totp-enroll.replace-confirm"].firstMatch
        XCTAssertTrue(
            replaceConfirm.waitForExistence(timeout: 5),
            "Replace confirmation was not presented for an entry with a code"
        )
        tapElement(replaceConfirm)

        // Cancelling the editor returns to the destination list instead of
        // destroying the incoming code.
        let editorCancel = app.buttons["entry-edit.cancel"]
        XCTAssertTrue(editorCancel.waitForExistence(timeout: 5), "Editor did not open after Replace")
        tapElement(editorCancel)

        let discardButton = app.buttons["Discard Changes"].firstMatch
        XCTAssertTrue(
            discardButton.waitForExistence(timeout: 5),
            "Discard prompt was not presented for the dirty enrollment editor"
        )
        tapElement(discardButton)

        waitForDestinationSheet()
        dismissDestinationSheet()
    }

    func testDeepLinkNewEntryPrefillsFromLink() {
        unlockSuccessfully()

        openOTPAuthURL("otpauth://totp/Fresh%20Service:alice@fresh.example?secret=JBSWY3DPEHPK3PXP&issuer=Fresh%20Service")
        waitForDestinationSheet()

        let newEntryButton = app.buttons["totp-enroll.new-entry"]
        XCTAssertTrue(newEntryButton.waitForExistence(timeout: 5), "New Entry button was not visible")
        tapElement(newEntryButton)

        let unionGroupOption = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'totp-enroll.group.' AND label CONTAINS[c] 'Union'")
        ).firstMatch
        XCTAssertTrue(
            unionGroupOption.waitForExistence(timeout: 5),
            "Union group option was not visible in the group picker"
        )
        tapElement(unionGroupOption)

        let titleField = app.textFields["entry-edit.title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Entry editor did not open for the new entry")
        XCTAssertEqual(
            titleField.value as? String,
            "Fresh Service",
            "New entry title was not prefilled from the link's issuer"
        )

        saveEditorAndWaitForDismissal()

        openGroup(named: "Union")
        openEntry(named: "Fresh Service")
        assertDetailRendersCode(digits: 6)
    }

    func testDeepLinkWhileLockedAlertsThenPromotesAfterUnlock() {
        // Still on the database list — no unlocked session yet.
        openOTPAuthURL("otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example")

        let unlockAlert = app.alerts["Unlock a Database"]
        XCTAssertTrue(
            unlockAlert.waitForExistence(timeout: KeeForgeUITestCase.ciElementTimeout),
            "The unlock-needed alert did not appear for a deep link without a session"
        )
        tapElement(unlockAlert.buttons["OK"])

        unlockSuccessfully()

        // The parked enrollment promotes onto the fresh session.
        waitForDestinationSheet()
        dismissDestinationSheet()
    }

    func testDeepLinkUnsupportedTypeShowsAlert() {
        openOTPAuthURL("otpauth://hotp/Legacy:bob@example.com?secret=JBSWY3DPEHPK3PXP&counter=1")

        let alert = app.alerts["Couldn’t Add Verification Code"]
        XCTAssertTrue(
            alert.waitForExistence(timeout: KeeForgeUITestCase.ciElementTimeout),
            "The unsupported-type alert did not appear for an otpauth://hotp link"
        )
        tapElement(alert.buttons["OK"])
    }

    func testDeepLinkReadOnlyDatabaseShowsExplanation() {
        unlockSuccessfully()

        openOTPAuthURL("otpauth://totp/Example:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example")

        let readOnlyTitle = app.staticTexts["Read-Only Database"]
        XCTAssertTrue(
            readOnlyTitle.waitForExistence(timeout: KeeForgeUITestCase.ciElementTimeout),
            "The read-only explanation did not appear for a read-only database"
        )
        dismissDestinationSheet()
    }
}
