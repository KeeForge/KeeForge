import XCTest
@testable import KeeForge

@MainActor
final class ReviewPromptServiceTests: XCTestCase {
    private let suiteName = "ReviewPromptServiceTests"
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: suiteName)!
        ReviewPromptService.defaults = testDefaults
        ReviewPromptService.resetForTesting()
        ReviewPromptService.minimumActions = 10
        ReviewPromptService.requestReviewHandler = nil
        ReviewPromptService.isAppStoreBuild = true
    }

    override func tearDown() {
        ReviewPromptService.resetForTesting()
        ReviewPromptService.defaults = .standard
        ReviewPromptService.requestReviewHandler = nil
        ReviewPromptService.isAppStoreBuild = true
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Action counting

    func testActionCountStartsAtZero() {
        XCTAssertEqual(ReviewPromptService.actionCount, 0)
    }

    func testRecordMeaningfulActionIncrementsCount() {
        ReviewPromptService.recordMeaningfulAction()
        XCTAssertEqual(ReviewPromptService.actionCount, 1)

        ReviewPromptService.recordMeaningfulAction()
        XCTAssertEqual(ReviewPromptService.actionCount, 2)
    }

    // MARK: - shouldPrompt logic

    func testShouldNotPromptBelowThreshold() {
        ReviewPromptService.actionCount = 9
        XCTAssertFalse(ReviewPromptService.shouldPrompt())
    }

    func testShouldPromptAtThreshold() {
        ReviewPromptService.actionCount = 10
        XCTAssertTrue(ReviewPromptService.shouldPrompt())
    }

    func testShouldPromptAboveThreshold() {
        ReviewPromptService.actionCount = 25
        XCTAssertTrue(ReviewPromptService.shouldPrompt())
    }

    func testShouldNotPromptIfAlreadyPrompted() {
        ReviewPromptService.actionCount = 20
        ReviewPromptService.hasPrompted = true
        XCTAssertFalse(ReviewPromptService.shouldPrompt())
    }

    func testOnceEverSemantics() {
        // First time: should prompt
        ReviewPromptService.actionCount = 10
        XCTAssertTrue(ReviewPromptService.shouldPrompt())

        // Mark as prompted
        ReviewPromptService.hasPrompted = true

        // Never again, even with more actions
        ReviewPromptService.actionCount = 100
        XCTAssertFalse(ReviewPromptService.shouldPrompt())
    }

    // MARK: - Custom threshold

    func testCustomMinimumActionsThreshold() {
        ReviewPromptService.minimumActions = 5
        ReviewPromptService.actionCount = 4
        XCTAssertFalse(ReviewPromptService.shouldPrompt())

        ReviewPromptService.actionCount = 5
        XCTAssertTrue(ReviewPromptService.shouldPrompt())
    }

    // MARK: - hasPrompted

    func testHasPromptedStartsFalse() {
        XCTAssertFalse(ReviewPromptService.hasPrompted)
    }

    // MARK: - resetForTesting

    func testResetClearsAllState() {
        ReviewPromptService.actionCount = 42
        ReviewPromptService.hasPrompted = true

        ReviewPromptService.resetForTesting()

        XCTAssertEqual(ReviewPromptService.actionCount, 0)
        XCTAssertFalse(ReviewPromptService.hasPrompted)
    }

    // MARK: - Presenter injection (cross-platform; macOS relies on this hook)

    func testRequestReviewInvokesInjectedHandlerWhenAppropriate() {
        var invoked = 0
        ReviewPromptService.requestReviewHandler = { invoked += 1 }
        ReviewPromptService.actionCount = 9 // recordMeaningfulAction pushes to 10

        ReviewPromptService.requestReviewIfAppropriate()

        XCTAssertEqual(invoked, 1)
        XCTAssertTrue(ReviewPromptService.hasPrompted)
    }

    func testRequestReviewDoesNotInvokeHandlerBelowThreshold() {
        var invoked = 0
        ReviewPromptService.requestReviewHandler = { invoked += 1 }
        ReviewPromptService.actionCount = 3

        ReviewPromptService.requestReviewIfAppropriate()

        XCTAssertEqual(invoked, 0)
        XCTAssertFalse(ReviewPromptService.hasPrompted)
    }

    func testRequestReviewSkipsHandlerForNonAppStoreBuild() {
        var invoked = 0
        ReviewPromptService.requestReviewHandler = { invoked += 1 }
        ReviewPromptService.isAppStoreBuild = false
        ReviewPromptService.actionCount = 9

        ReviewPromptService.requestReviewIfAppropriate()

        XCTAssertEqual(invoked, 0, "Non-App-Store builds must not present a StoreKit review prompt")
    }

    func testRequestReviewPromptsOnlyOnce() {
        var invoked = 0
        ReviewPromptService.requestReviewHandler = { invoked += 1 }
        ReviewPromptService.actionCount = 9

        ReviewPromptService.requestReviewIfAppropriate()
        ReviewPromptService.actionCount = 100
        ReviewPromptService.requestReviewIfAppropriate()

        XCTAssertEqual(invoked, 1)
    }
}
