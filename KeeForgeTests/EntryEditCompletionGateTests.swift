import XCTest
@testable import KeeForge

final class EntryEditCompletionGateTests: XCTestCase {
    func testFinishWithoutConflictReportsImmediately() {
        var gate = EntryEditCompletionGate()

        XCTAssertEqual(gate.finish(.saved, hasSaveConflict: false), .saved)
        XCTAssertNil(gate.heldCompletion)
    }

    func testFinishDuringConflictHoldsTheCompletion() {
        var gate = EntryEditCompletionGate()

        XCTAssertNil(gate.finish(.saved, hasSaveConflict: true))
        XCTAssertEqual(gate.heldCompletion, .saved)
    }

    func testHeldCompletionIsReleasedOnceSettledAndOnlyOnce() {
        var gate = EntryEditCompletionGate()
        _ = gate.finish(.saved, hasSaveConflict: true)

        XCTAssertNil(gate.conflictSettled(false), "Still unsettled: the editor must stay open")
        XCTAssertEqual(gate.conflictSettled(true), .saved)
        XCTAssertNil(gate.heldCompletion)
        XCTAssertNil(gate.conflictSettled(true), "A second settle must not report twice")
    }

    func testSettlingWithNothingHeldReportsNothing() {
        var gate = EntryEditCompletionGate()

        XCTAssertNil(gate.conflictSettled(true))
    }

    func testConflictedDeleteStillReportsDeleted() {
        var gate = EntryEditCompletionGate()
        _ = gate.finish(.deleted, hasSaveConflict: true)

        XCTAssertEqual(gate.conflictSettled(true), .deleted)
    }

    func testRetryingSaveAfterCancelReportsThroughFinishNotTheHold() {
        // Alert Cancel keeps the conflict; the user hits Save again and it
        // succeeds. The direct path reports and drops the stale hold, so the
        // later settle cannot report a second time.
        var gate = EntryEditCompletionGate()
        _ = gate.finish(.saved, hasSaveConflict: true)

        XCTAssertEqual(gate.finish(.saved, hasSaveConflict: false), .saved)
        XCTAssertNil(gate.heldCompletion)
        XCTAssertNil(gate.conflictSettled(true))
    }

    func testReconflictKeepsTheLatestCompletionHeld() {
        var gate = EntryEditCompletionGate()
        _ = gate.finish(.saved, hasSaveConflict: true)
        _ = gate.finish(.deleted, hasSaveConflict: true)

        XCTAssertEqual(gate.conflictSettled(true), .deleted)
    }

    func testIsSettledRequiresNoConflictNoMergeResultAndCleanDraft() {
        XCTAssertTrue(EntryEditCompletionGate.isSettled(hasSaveConflict: false, isPresentingMergeResult: false, isDirty: false))
        XCTAssertFalse(EntryEditCompletionGate.isSettled(hasSaveConflict: true, isPresentingMergeResult: false, isDirty: false))
        XCTAssertFalse(
            EntryEditCompletionGate.isSettled(hasSaveConflict: false, isPresentingMergeResult: true, isDirty: false),
            "The merge summary/failure alerts present from the editor too; closing under them hits the same race"
        )
        XCTAssertFalse(
            EntryEditCompletionGate.isSettled(hasSaveConflict: false, isPresentingMergeResult: false, isDirty: true),
            "A conflict cleared ahead of a fresh write leaves the draft dirty; the editor waits for that write"
        )
    }

    func testMergeSuccessSequenceClosesOnlyAfterSummaryDismissed() {
        // Save conflicts → Merge Changes → summary alert up (conflict already
        // cleared, draft clean) → OK. The editor must close on OK, not before.
        var gate = EntryEditCompletionGate()
        XCTAssertNil(gate.finish(.saved, hasSaveConflict: true))

        let summaryUp = EntryEditCompletionGate.isSettled(hasSaveConflict: false, isPresentingMergeResult: true, isDirty: false)
        XCTAssertNil(gate.conflictSettled(summaryUp))

        let summaryDismissed = EntryEditCompletionGate.isSettled(hasSaveConflict: false, isPresentingMergeResult: false, isDirty: false)
        XCTAssertEqual(gate.conflictSettled(summaryDismissed), .saved)
    }

    func testMergeDeclinedThenCancelKeepsEditorOpen() {
        // Merge fails → failure alert → OK re-presents the conflict → Cancel.
        // The conflict never clears, so the completion stays held.
        var gate = EntryEditCompletionGate()
        _ = gate.finish(.saved, hasSaveConflict: true)

        XCTAssertNil(gate.conflictSettled(EntryEditCompletionGate.isSettled(hasSaveConflict: true, isPresentingMergeResult: true, isDirty: true)))
        XCTAssertNil(gate.conflictSettled(EntryEditCompletionGate.isSettled(hasSaveConflict: true, isPresentingMergeResult: false, isDirty: true)))
        XCTAssertEqual(gate.heldCompletion, .saved)
    }
}
