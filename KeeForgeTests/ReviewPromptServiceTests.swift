import XCTest
@testable import KeeForge

private final class PromptCounter {
    var count = 0
}

@MainActor
final class ReviewPromptServiceTests: XCTestCase {
    private let suiteName = "ReviewPromptServiceTests"
    private var testDefaults: UserDefaults!
    private let counter = PromptCounter()
    private var promptCount: Int { counter.count }

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: suiteName)!
        ReviewPromptService.defaults = testDefaults
        ReviewPromptService.resetForTesting()
        ReviewPromptService.minimumSuccessfulSaves = 3
        ReviewPromptService.minimumSuccessfulAutoFills = 5
        ReviewPromptService.currentVersion = "1.0"
        ReviewPromptService.isAppStoreBuild = true
        ReviewPromptService.isSuppressedForUITesting = false
        SettingsService.successfulAutoFillCount = 0
        counter.count = 0
        let counter = counter
        ReviewPromptService.requestReviewHandler = { counter.count += 1 }
    }

    override func tearDown() {
        ReviewPromptService.resetForTesting()
        ReviewPromptService.defaults = .standard
        ReviewPromptService.requestReviewHandler = nil
        ReviewPromptService.currentVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ReviewPromptService.isAppStoreBuild = true
        ReviewPromptService.isSuppressedForUITesting = false
        SettingsService.successfulAutoFillCount = 0
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func save(times: Int, followsError: Bool = false) {
        for _ in 0..<times {
            ReviewPromptService.noteSuccessfulSave(followsError: followsError)
        }
    }

    // MARK: - Saves

    func testSavesBelowThresholdDoNotPrompt() {
        save(times: 2)
        XCTAssertEqual(ReviewPromptService.successfulSaveCount, 2)
        XCTAssertEqual(promptCount, 0)
        XCTAssertNil(ReviewPromptService.lastPromptedVersion)
    }

    func testSaveReachingThresholdPromptsAndRecordsVersion() {
        save(times: 3)
        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(ReviewPromptService.lastPromptedVersion, "1.0")
    }

    func testPromptsAtMostOncePerVersion() {
        save(times: 10)
        XCTAssertEqual(promptCount, 1)
    }

    func testNewVersionPromptsAgain() {
        save(times: 3)
        ReviewPromptService.currentVersion = "1.1"
        save(times: 1)
        XCTAssertEqual(promptCount, 2)
        XCTAssertEqual(ReviewPromptService.lastPromptedVersion, "1.1")
    }

    func testSaveRightAfterErrorDoesNotPromptButStillCounts() {
        save(times: 2)
        save(times: 1, followsError: true)
        XCTAssertEqual(promptCount, 0)
        XCTAssertEqual(ReviewPromptService.successfulSaveCount, 3)
        XCTAssertNil(ReviewPromptService.lastPromptedVersion, "A skipped prompt must not use up the version")

        save(times: 1)
        XCTAssertEqual(promptCount, 1)
    }

    // MARK: - AutoFill

    func testUnlockPromptsOnceAutoFillThresholdReached() {
        SettingsService.successfulAutoFillCount = 4
        ReviewPromptService.noteSuccessfulUnlock(followsError: false)
        XCTAssertEqual(promptCount, 0)

        SettingsService.successfulAutoFillCount = 5
        ReviewPromptService.noteSuccessfulUnlock(followsError: false)
        ReviewPromptService.noteSuccessfulUnlock(followsError: false)
        XCTAssertEqual(promptCount, 1)
    }

    func testUnlockAfterFailedAttemptDoesNotPrompt() {
        SettingsService.successfulAutoFillCount = 5
        ReviewPromptService.noteSuccessfulUnlock(followsError: true)
        XCTAssertEqual(promptCount, 0)
        XCTAssertNil(ReviewPromptService.lastPromptedVersion)
    }

    func testUnlockWithoutAutoFillUseDoesNotPromptOnSavesAlone() {
        save(times: 3)
        ReviewPromptService.currentVersion = "1.1"
        ReviewPromptService.noteSuccessfulUnlock(followsError: false)
        XCTAssertEqual(promptCount, 1, "Unlocks prompt only on AutoFill use, not on past saves")
    }

    func testSaveAndAutoFillShareOnePromptPerVersion() {
        SettingsService.successfulAutoFillCount = 5
        ReviewPromptService.noteSuccessfulUnlock(followsError: false)
        save(times: 3)
        XCTAssertEqual(promptCount, 1)
    }

    // MARK: - Gates

    func testMissingVersionNeverPrompts() {
        ReviewPromptService.currentVersion = nil
        save(times: 3)
        XCTAssertEqual(promptCount, 0)
    }

    func testNonAppStoreBuildDoesNotPrompt() {
        ReviewPromptService.isAppStoreBuild = false
        save(times: 3)
        XCTAssertEqual(promptCount, 0, "Non-App-Store builds must not present a StoreKit review prompt")
    }

    func testUITestingSuppressesPrompt() {
        ReviewPromptService.isSuppressedForUITesting = true
        save(times: 3)
        XCTAssertEqual(promptCount, 0, "UI-test launches must not present the review prompt")
    }

    func testResetClearsState() {
        save(times: 3)
        ReviewPromptService.resetForTesting()
        XCTAssertEqual(ReviewPromptService.successfulSaveCount, 0)
        XCTAssertNil(ReviewPromptService.lastPromptedVersion)
    }
}
