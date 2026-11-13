#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class MacDatabaseWindowRegistryTests: XCTestCase {
    func testLookupUsesWindowIdentityAndDatabaseIDRegardlessOfSelection() throws {
        let store = DatabaseSessionStore()
        let registry = MacDatabaseWindowRegistry(sessionStore: store)
        let first = store.open(try reference())
        let second = store.open(try reference())
        store.activeSessionID = second.databaseReference.id
        let a = NSWindow()
        let b = NSWindow()
        registry.register(a, databaseID: first.databaseReference.id)
        registry.register(b, databaseID: second.databaseReference.id)
        XCTAssertTrue(registry.session(for: a) === first)
        XCTAssertTrue(registry.session(for: b) === second)
        XCTAssertNil(registry.session(for: NSWindow()))
        XCTAssertNil(registry.session(for: NSPanel()))
        store.activeSessionID = nil
        XCTAssertTrue(registry.session(for: a) === first)
    }

    func testSheetAndChildResolveToTheirDatabaseParent() {
        let registry = MacDatabaseWindowRegistry(sessionStore: DatabaseSessionStore())
        let window = NSWindow()
        let child = NSWindow()
        let sheet = RegistrySheetWindow()
        sheet.databaseParent = window
        window.addChildWindow(child, ordered: .above)
        defer { window.removeChildWindow(child) }
        let registration = registry.register(window, databaseID: UUID())
        XCTAssertTrue(registry.registration(for: sheet) === registration)
        XCTAssertTrue(registry.registration(for: child) === registration)
    }

    func testReplacementAndUnregisterInvalidateCallbacksAndRestorationState() {
        let registry = MacDatabaseWindowRegistry(sessionStore: DatabaseSessionStore())
        let window = NSWindow()
        var invalidations = 0
        let first = registry.register(window, databaseID: UUID(), isRestoring: true)
        first.onUnregister = { invalidations += 1 }
        XCTAssertTrue(first.isRestoring)
        let second = registry.register(window, databaseID: UUID())
        XCTAssertFalse(registry.isCurrent(first))
        XCTAssertNil(first.onUnregister)
        XCTAssertFalse(second.isRestoring)
        XCTAssertEqual(invalidations, 1)
        second.onUnregister = { invalidations += 1 }
        registry.unregister(window)
        XCTAssertNil(second.onUnregister)
        XCTAssertNil(registry.registration(for: window))
        XCTAssertEqual(invalidations, 2)
    }

    func testAutomaticUnlockAdmitsOnlyTheWindowsSessionOutsideRestoration() throws {
        let store = DatabaseSessionStore()
        let registry = MacDatabaseWindowRegistry(sessionStore: store)
        let shown = store.open(try reference())
        let background = store.open(try reference())
        let window = NSWindow()
        registry.register(window, databaseID: shown.databaseReference.id, isRestoring: true)
        XCTAssertFalse(registry.admitsAutomaticUnlock(for: shown, in: window))

        registry.register(window, databaseID: shown.databaseReference.id)
        XCTAssertTrue(registry.admitsAutomaticUnlock(for: shown, in: window))
        XCTAssertFalse(registry.admitsAutomaticUnlock(for: background, in: window))
        XCTAssertFalse(registry.admitsAutomaticUnlock(for: shown, in: NSWindow()))
        XCTAssertFalse(registry.admitsAutomaticUnlock(for: shown, in: nil))
    }

    private func reference() throws -> DatabaseReference {
        try TestDatabaseSupport.makeReference(for: TestDatabaseSupport.fixtureURL(
            named: "test", bundle: Bundle(for: Self.self)))
    }
}

@MainActor
private final class RegistrySheetWindow: NSWindow {
    weak var databaseParent: NSWindow?
    override var sheetParent: NSWindow? { databaseParent }
}
#endif
