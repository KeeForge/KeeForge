#if os(macOS)
import XCTest
@testable import KeeForge

@MainActor
final class MacApplicationRoutingTests: XCTestCase {
    func testQueuedFilesAndDatabaseIDsDrainInArrivalOrder() {
        let routing = MacApplicationRouting()
        let first = UUID(), second = UUID(), third = UUID()
        let file = MacApplicationRouting.OpenRequest.file(URL(fileURLWithPath: "/tmp/vault.kdbx"), databaseID: second)
        XCTAssertEqual(routing.requestOpen(.database(first), openDatabaseIDs: []), [])
        XCTAssertEqual(routing.requestOpen(file, openDatabaseIDs: []), [])
        XCTAssertEqual(routing.requestOpen(.database(third), openDatabaseIDs: []), [])
        XCTAssertEqual(routing.beginStartup(transitionNotice: false, whatsNew: false, automaticOpen: UUID()), [])
        XCTAssertEqual(routing.becomeReady(), [.open(.database(first)), .open(file), .open(.database(third))])
        XCTAssertEqual(routing.becomeReady(), [])
    }

    func testQueuedDuplicatesAndAlreadyOpenDatabasesFrontInsteadOfOpening() {
        let routing = MacApplicationRouting()
        let first = UUID(), second = UUID()
        XCTAssertEqual(routing.requestOpen(.database(first), openDatabaseIDs: []), [])
        XCTAssertEqual(routing.requestOpen(.file(URL(fileURLWithPath: "/tmp/vault.kdbx"), databaseID: first), openDatabaseIDs: []), [])
        XCTAssertEqual(routing.requestOpen(.database(second), openDatabaseIDs: [second]), [])
        XCTAssertEqual(routing.beginStartup(transitionNotice: false, whatsNew: false, automaticOpen: nil), [])
        XCTAssertEqual(routing.becomeReady(openDatabaseIDs: [second]), [.open(.database(first)), .front(first), .front(second)])
        XCTAssertEqual(routing.requestOpen(.database(second), openDatabaseIDs: [second]), [.front(second)])
    }

    func testLaunchPresentationsGateAutomaticOpeningAndAuthenticationInOrder() {
        let routing = MacApplicationRouting()
        let automatic = UUID()
        XCTAssertEqual(routing.beginStartup(transitionNotice: true, whatsNew: true, automaticOpen: automatic),
                       [.showLauncher, .present(.transitionNotice)])
        XCTAssertFalse(routing.canAuthenticate)
        XCTAssertEqual(routing.becomeReady(), [])
        XCTAssertEqual(routing.finishLaunchPresentation(.whatsNew), [])
        XCTAssertEqual(routing.finishLaunchPresentation(.transitionNotice), [.showLauncher, .present(.whatsNew)])
        XCTAssertFalse(routing.canAuthenticate)
        XCTAssertEqual(routing.finishLaunchPresentation(.whatsNew), [.open(.database(automatic))])
        XCTAssertTrue(routing.canAuthenticate)
        XCTAssertEqual(routing.finishLaunchPresentation(.whatsNew), [])
    }

    func testExplicitOpensDuringLaunchSuppressAutomaticOpeningAndWaitForDismissal() {
        let routing = MacApplicationRouting()
        let explicit = UUID()
        _ = routing.beginStartup(transitionNotice: false, whatsNew: true, automaticOpen: UUID())
        _ = routing.becomeReady()
        XCTAssertEqual(routing.requestOpen(.database(explicit), openDatabaseIDs: []), [])
        XCTAssertEqual(routing.finishLaunchPresentation(.whatsNew), [.open(.database(explicit))])
    }

    func testReadyBeforeStartupStillWaitsAndAutomaticOpenCanFrontExisting() {
        let routing = MacApplicationRouting()
        let id = UUID()
        XCTAssertEqual(routing.becomeReady(), [])
        XCTAssertFalse(routing.canAuthenticate)
        _ = routing.beginStartup(transitionNotice: false, whatsNew: true, automaticOpen: id)
        XCTAssertEqual(routing.finishLaunchPresentation(.whatsNew, openDatabaseIDs: [id]), [.front(id)])
    }

    func testRestorationWaitsForLaunchPresentationsAndPrecedesQueuedAndAutomaticOpens() {
        let routing = MacApplicationRouting()
        let file = MacApplicationRouting.OpenRequest.file(URL(fileURLWithPath: "/tmp/vault.kdbx"), databaseID: UUID())
        XCTAssertEqual(routing.requestOpen(file, openDatabaseIDs: []), [])
        XCTAssertEqual(routing.beginStartup(transitionNotice: false, whatsNew: true, restoresWindows: true, automaticOpen: nil),
                       [.showLauncher, .present(.whatsNew)])
        XCTAssertEqual(routing.becomeReady(), [], "Nothing is restored behind a launch presentation")
        XCTAssertEqual(routing.finishLaunchPresentation(.whatsNew), [.restoreWindows, .open(file)])
        XCTAssertEqual(routing.becomeReady(), [], "Restoration happens once")

        let quick = UUID()
        let second = MacApplicationRouting()
        XCTAssertEqual(second.beginStartup(transitionNotice: false, whatsNew: false, restoresWindows: true, automaticOpen: quick), [])
        XCTAssertEqual(second.becomeReady(), [.restoreWindows, .open(.database(quick))])

        let none = MacApplicationRouting()
        _ = none.beginStartup(transitionNotice: false, whatsNew: false, automaticOpen: nil)
        XCTAssertEqual(none.becomeReady(), [], "No restoration without a plan")
    }

    func testEnrollmentBindsArrivalTargetRegardlessOfSubsequentOpenRequests() {
        let routing = MacApplicationRouting()
        let destination = UUID(), other = UUID()
        XCTAssertEqual(routing.receiveEnrollment(targetDatabaseID: destination), [.bindEnrollment(destination)])
        _ = routing.requestOpen(.database(other), openDatabaseIDs: [])
        _ = routing.dockReopen(hasVisibleWindows: true)
        XCTAssertEqual(routing.enrollmentDestination, destination)
        XCTAssertEqual(routing.receiveEnrollment(targetDatabaseID: other), [.bindEnrollment(other)])
        XCTAssertEqual(routing.enrollmentDestination, other)
    }

    func testUnassignedEnrollmentAsksLauncherAndOnlyExplicitChoiceBindsIt() {
        let routing = MacApplicationRouting()
        let id = UUID()
        XCTAssertEqual(routing.receiveEnrollment(targetDatabaseID: nil), [.showLauncher, .askEnrollmentDestination])
        _ = routing.requestOpen(.database(id), openDatabaseIDs: [])
        XCTAssertNil(routing.enrollmentDestination)
        XCTAssertEqual(routing.chooseEnrollmentDestination(id), [.bindEnrollment(id)])
        XCTAssertEqual(routing.enrollmentDestination, id)
    }

    func testLauncherVisibilityAndDockReopenWithAndWithoutVisibleWindows() {
        let routing = MacApplicationRouting()
        XCTAssertEqual(routing.ensureVisibleWindow(hasVisibleWindows: false), [.showLauncher])
        XCTAssertEqual(routing.ensureVisibleWindow(hasVisibleWindows: true), [])
        XCTAssertEqual(routing.dockReopen(hasVisibleWindows: false), [.showLauncher])
        XCTAssertEqual(routing.dockReopen(hasVisibleWindows: true), [])
    }
}
#endif
