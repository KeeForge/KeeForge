import XCTest
@testable import KeeForge

/// Off-simulator coverage for `StoreKitManager`.
///
/// StoreKit's live `Product`/`Transaction` flows require a StoreKit
/// configuration and the simulator, so they are exercised via manual
/// verification (see the group's risks notes). What we can pin down here as
/// pure logic is the `PurchaseResult` contract that the Tip Jar UI switches on —
/// in particular that a pending / Ask-to-Buy purchase is reported distinctly and
/// is no longer conflated with a user cancellation.
final class StoreKitManagerTests: XCTestCase {
    typealias PurchaseResult = StoreKitManager.PurchaseResult

    func testPendingIsDistinctFromCancelled() {
        // Regression guard: a deferred (Ask to Buy / SCA) purchase must not be
        // reported as a silent cancellation, otherwise the user gets no feedback.
        XCTAssertNotEqual(PurchaseResult.pending, PurchaseResult.cancelled)
    }

    func testPendingIsDistinctFromSuccess() {
        XCTAssertNotEqual(PurchaseResult.pending, PurchaseResult.success)
    }

    func testErrorEqualityCarriesMessage() {
        XCTAssertEqual(PurchaseResult.error("boom"), PurchaseResult.error("boom"))
        XCTAssertNotEqual(PurchaseResult.error("boom"), PurchaseResult.error("other"))
    }

    func testErrorIsDistinctFromTerminalCases() {
        XCTAssertNotEqual(PurchaseResult.error("x"), PurchaseResult.success)
        XCTAssertNotEqual(PurchaseResult.error("x"), PurchaseResult.cancelled)
        XCTAssertNotEqual(PurchaseResult.error("x"), PurchaseResult.pending)
    }
}
