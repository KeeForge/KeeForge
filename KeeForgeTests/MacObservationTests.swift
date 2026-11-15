#if os(macOS)
import Observation
import XCTest
@testable import KeeForge

@MainActor
final class MacObservationTests: XCTestCase {
    @Observable final class Session {
        var value = 0
    }

    @Observable final class Store {
        var session: Session
        init(session: Session) { self.session = session }
    }

    func testFiresAfterMutationAndRearms() async {
        let session = Session()
        let observation = MacObservation()
        var values: [Int] = []
        let first = expectation(description: "First change")
        let second = expectation(description: "Rearmed change")
        observation.start(reading: { session.value }) { value in
            values.append(value)
            if value == 1 { first.fulfill() }
            if value == 2 { second.fulfill() }
        }
        XCTAssertEqual(values, [0])
        session.value = 1
        await fulfillment(of: [first], timeout: 2)
        session.value = 2
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(values, [0, 1, 2])
    }

    func testCancellationRejectsAlreadyQueuedAndLaterChanges() async {
        let session = Session()
        let observation = MacObservation()
        var values: [Int] = []
        observation.start(reading: { session.value }) { values.append($0) }
        session.value = 1
        observation.cancel()
        await drainMainActor()
        session.value = 2
        await drainMainActor()
        XCTAssertEqual(values, [0])
    }

    func testReplacementIgnoresOldSessionIncludingQueuedCallback() async {
        let old = Session()
        let replacement = Session()
        let observation = MacObservation()
        var oldValues: [Int] = []
        var newValues: [Int] = []
        observation.start(reading: { old.value }) { oldValues.append($0) }
        old.value = 1
        let changed = expectation(description: "Replacement changed")
        observation.start(reading: { replacement.value }) {
            newValues.append($0)
            if $0 == 3 { changed.fulfill() }
        }
        await drainMainActor()
        old.value = 2
        replacement.value = 3
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(oldValues, [0])
        XCTAssertEqual(newValues, [0, 3])
    }

    func testSessionSelectedByObservedStoreReplacesItsDependencies() async {
        let old = Session()
        let replacement = Session()
        replacement.value = 10
        let store = Store(session: old)
        let observation = MacObservation()
        var values: [Int] = []
        let switched = expectation(description: "Session switched")
        let changed = expectation(description: "Current session changed")
        observation.start(reading: { store.session.value }) {
            values.append($0)
            if $0 == 10 { switched.fulfill() }
            if $0 == 11 { changed.fulfill() }
        }
        old.value = 1
        store.session = replacement
        await fulfillment(of: [switched], timeout: 2)
        old.value = 2
        replacement.value = 11
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(values, [0, 10, 11])
    }

    func testOwnerDeallocationStopsQueuedObservation() async {
        let session = Session()
        var observation: MacObservation? = MacObservation()
        weak var weakObservation = observation
        var values: [Int] = []
        observation?.start(reading: { session.value }) { values.append($0) }
        session.value = 1
        observation = nil
        XCTAssertNil(weakObservation)
        await drainMainActor()
        session.value = 2
        await drainMainActor()
        XCTAssertEqual(values, [0])
    }

    private func drainMainActor() async {
        await Task { @MainActor in }.value
    }
}
#endif
