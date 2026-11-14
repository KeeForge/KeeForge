#if os(macOS)
import XCTest
@testable import KeeForge

@MainActor
final class MacCopyFeedbackTests: XCTestCase {
    func testATickShowsForOneAndAHalfSecondsThenClears() async {
        let sleeper = Sleeper()
        let feedback = MacCopyFeedback(sleep: sleeper.sleep)
        let entryID = UUID()

        feedback.show(.password, for: entryID)
        XCTAssertEqual(feedback.copied, MacCopyFeedback.Copied(entryID: entryID, field: .password))
        XCTAssertEqual(feedback.field(copiedFor: entryID), .password)
        XCTAssertNil(feedback.field(copiedFor: UUID()))
        await sleeper.waitForSleeps(1)
        XCTAssertEqual(sleeper.durations, [.milliseconds(1500)], "The board's 1.5 seconds")
        XCTAssertNotNil(feedback.copied)

        sleeper.wakeAll()
        await feedback.clearTask?.value
        XCTAssertNil(feedback.copied)
        XCTAssertNil(feedback.clearTask)
    }

    func testALaterCopyRestartsTheDurationAndAnEarlierTimerCannotClearIt() async {
        let sleeper = Sleeper()
        let feedback = MacCopyFeedback(sleep: sleeper.sleep)
        let first = UUID()
        let second = UUID()

        feedback.show(.username, for: first)
        await sleeper.waitForSleeps(1)
        feedback.show(.verificationCode, for: second)
        await sleeper.waitForSleeps(2)
        sleeper.wake(0)
        await Task.yield()
        XCTAssertEqual(feedback.copied, MacCopyFeedback.Copied(entryID: second, field: .verificationCode))
        XCTAssertNil(feedback.field(copiedFor: first))

        sleeper.wake(1)
        await feedback.clearTask?.value
        XCTAssertNil(feedback.copied)
    }

    func testRecordingTicksOnlyWhenTheCopyHappens() {
        let feedback = MacCopyFeedback(sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let entryID = UUID()
        var copied: [String] = []
        let copy = feedback.recording(.url, for: entryID) { copied.append($0) }
        XCTAssertNil(feedback.copied, "Wrapping a copy is not a copy")

        copy("https://example.com")
        XCTAssertEqual(copied, ["https://example.com"])
        XCTAssertEqual(feedback.copied, MacCopyFeedback.Copied(entryID: entryID, field: .url))
        feedback.clear()
        XCTAssertNil(feedback.copied)
        XCTAssertNil(feedback.clearTask)
    }

    func testLabelsAndPresentationResetClearTheTick() {
        XCTAssertEqual(MacCopyFeedback.Field.username.copiedLabel, String(localized: "Username copied"))
        XCTAssertEqual(MacCopyFeedback.Field.password.copiedLabel, String(localized: "Password copied"))
        XCTAssertEqual(MacCopyFeedback.Field.url.copiedLabel, String(localized: "URL copied"))
        XCTAssertEqual(MacCopyFeedback.Field.verificationCode.copiedLabel, String(localized: "Verification code copied"))

        let presentation = MacWorkspacePresentation()
        presentation.copyFeedback.show(.password, for: UUID())
        presentation.reset()
        XCTAssertNil(presentation.copyFeedback.copied, "The workspace host resets on lock")
    }

    @MainActor
    private final class Sleeper {
        private(set) var durations: [Duration] = []
        private var continuations: [CheckedContinuation<Void, Never>?] = []
        private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

        var sleep: @Sendable (Duration) async throws -> Void {
            { [weak self] duration in await self?.suspend(duration) }
        }

        private func suspend(_ duration: Duration) async {
            await withCheckedContinuation { continuation in
                durations.append(duration)
                continuations.append(continuation)
                if let waiter, continuations.count >= waiter.count {
                    self.waiter = nil
                    waiter.continuation.resume()
                }
            }
        }

        func waitForSleeps(_ count: Int) async {
            guard continuations.count < count else { return }
            await withCheckedContinuation { waiter = (count, $0) }
        }

        func wake(_ index: Int) {
            continuations[index]?.resume()
            continuations[index] = nil
        }

        func wakeAll() {
            for index in continuations.indices { wake(index) }
        }
    }
}
#endif
