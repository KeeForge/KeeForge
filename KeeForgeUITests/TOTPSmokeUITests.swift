import XCTest

// Happy-path smoke coverage for the TOTP journey in entry detail: the code
// renders and the copy control is present. RFC 6238 code generation is
// unit-tested (`TOTPGeneratorTests`); this class proves the UI wiring only —
// deliberately not the exact code value or countdown timing, both of which
// are time-dependent and would make the test flaky.
@MainActor
final class TOTPSmokeUITests: UnlockedDatabaseUITestCase {
    // `autofill-union.kdbx`'s "Union News" entry (in its `Union` group)
    // carries a TOTP via the KeePassXC `otp` field; see
    // `TestFixtures/README.md`. Shares `test.kdbx`'s password
    // (`testpassword123`), the default `unlockSuccessfully()` uses.
    override var databaseFixtureName: String { "autofill-union" }

    func testTOTPCodeRendersAndCopyControlIsPresent() {
        unlockSuccessfully()

        openFixtureEntry(groupName: "Union", entryName: "Union News")

        let totpCode = app.staticTexts["entry.totp.code"]
        XCTAssertTrue(
            revealElement(totpCode, in: scrollableContainer()),
            "TOTP code was not visible in entry detail"
        )

        let code = totpCode.label
        XCTAssertEqual(code.count, 6, "Expected a 6-digit TOTP code, got '\(code)'")
        XCTAssertTrue(code.allSatisfy(\.isNumber), "Expected TOTP code to be numeric, got '\(code)'")

        let copyButton = app.buttons["entry.copy.totp"]
        XCTAssertTrue(
            revealElement(copyButton, in: scrollableContainer()),
            "TOTP copy control was not visible"
        )
        XCTAssertTrue(copyButton.isHittable, "TOTP copy control should be hittable")
    }
}
