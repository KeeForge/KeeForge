import XCTest

// Happy-path smoke coverage for the read-only entry-attachments list and its
// QuickLook preview sheet. Uses the `attachments` compatibility fixture
// (password `testpassword123`), which has a real KDBX4 binary pool with a
// non-ASCII attachment name and a small PNG, unlike `test.kdbx` which has no
// attachments at all.
@MainActor
final class EntryAttachmentsSmokeUITests: UnlockedDatabaseUITestCase {
    override var databaseFixtureName: String { "attachments" }

    func testAttachmentsSectionShowsExpectedRowsWithNameAndSize() {
        unlockSuccessfully()

        openFixtureEntry(groupName: "Attachments", entryName: "Multi Attachment Entry")

        let firstRow = app.buttons["entry.attachment.0"]
        let secondRow = app.buttons["entry.attachment.1"]

        XCTAssertTrue(revealElement(firstRow), "First attachment row was not visible")
        XCTAssertTrue(revealElement(secondRow), "Second attachment row was not visible")

        XCTAssertTrue(firstRow.label.contains("note-ü.txt"), "Expected first row to show 'note-ü.txt', got: \(firstRow.label)")
        XCTAssertTrue(secondRow.label.contains("pixel.png"), "Expected second row to show 'pixel.png', got: \(secondRow.label)")

        // Tapping a row resolves its bytes; the resolved size is rendered by
        // ByteCountFormatter as "<n> bytes" in a caption that SwiftUI folds
        // into the row button's own accessibility label (e.g.
        // "note-ü.txt, 71 bytes"). Assert the byte-count text appears on the
        // row label once resolution completes.
        tapElement(firstRow)
        let resolvedFirstRow = app.buttons.matching(
            NSPredicate(format: "identifier == 'entry.attachment.0' AND label CONTAINS[c] 'byte'")
        ).firstMatch
        XCTAssertTrue(resolvedFirstRow.waitForExistence(timeout: 10), "Expected a formatted byte-count caption after resolving the first attachment")
        dismissQuickLookIfPresented()

        // Each row is a distinct button identified by its index prefix; there
        // should be at least two of them for this entry.
        let attachmentRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'entry.attachment.' AND NOT identifier ENDSWITH 'share'")
        )
        XCTAssertGreaterThanOrEqual(attachmentRows.count, 2, "Expected at least two attachment rows")
    }

    func testTappingAttachmentRowOpensAndDismissesQuickLookPreview() {
        unlockSuccessfully()

        openFixtureEntry(groupName: "Attachments", entryName: "Multi Attachment Entry")

        let firstRow = app.buttons["entry.attachment.0"]
        XCTAssertTrue(revealElement(firstRow), "First attachment row was not visible")
        tapElement(firstRow)

        // Once the bytes resolve, the row exposes an in-row share affordance and
        // the QuickLook preview sheet presents its preview surface.
        let shareButton = app.buttons["entry.attachment.share"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 10), "Share button did not appear once attachment bytes resolved")

        let quickLookPreview = quickLookPreviewElement
        XCTAssertTrue(quickLookPreview.waitForExistence(timeout: 10), "QuickLook preview sheet did not appear")

        dismissQuickLookIfPresented()

        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 10),
            "Entry detail should still be visible after dismissing the QuickLook preview"
        )
    }

    /// The `QLPreviewController` embedded in the SwiftUI sheet renders as an
    /// `QLPreviewControllerView` element rather than a bordered navigation
    /// container, so query it directly instead of looking for chrome buttons.
    private var quickLookPreviewElement: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "QLPreviewControllerView").firstMatch
    }

    /// Dismisses the QuickLook preview sheet if it is currently presented.
    /// The sheet has no navigation "Done" button, so dismiss it with the
    /// standard sheet swipe-down gesture. Safe to call when no sheet is showing.
    private func dismissQuickLookIfPresented() {
        let quickLookPreview = quickLookPreviewElement
        guard quickLookPreview.waitForExistence(timeout: 5) else { return }
        // Swipe the sheet down from near its top to dismiss it.
        app.swipeDown(velocity: .fast)
        _ = quickLookPreview.waitForNonExistence(timeout: 10)
    }
}
