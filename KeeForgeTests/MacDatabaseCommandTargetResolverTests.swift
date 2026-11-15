#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class MacDatabaseCommandTargetResolverTests: XCTestCase {
    private final class Target {}

    private let databaseA = NSWindow()
    private let databaseB = NSWindow()
    private let launcher = NSWindow()
    private let settings = NSWindow()
    private let targetA = Target()
    private let targetB = Target()

    func testKeyDatabaseWindowWinsOverMainWindow() {
        XCTAssertTrue(resolve(key: databaseA, main: databaseB) === targetA)
        XCTAssertTrue(resolve(key: databaseB, main: databaseA) === targetB)
    }

    func testKeySheetResolvesToItsParentDatabase() {
        let sheet = ResolverSheetWindow()
        sheet.owner = databaseB
        XCTAssertTrue(resolve(key: sheet, main: databaseA) === targetB)
        let nested = ResolverSheetWindow()
        nested.owner = sheet
        XCTAssertTrue(resolve(key: nested, main: databaseA) === targetB)
    }

    func testAuxiliaryKeyWindowUsesTheMainDatabaseWindow() {
        XCTAssertTrue(resolve(key: settings, main: databaseA) === targetA)
        XCTAssertNil(resolve(key: settings, main: nil))
        XCTAssertNil(resolve(key: settings, main: launcher))
        XCTAssertTrue(resolve(key: nil, main: databaseB) === targetB)
    }

    func testDatabasesWindowDisablesDatabaseCommands() {
        XCTAssertNil(resolve(key: launcher, main: databaseA))
        let sheet = ResolverSheetWindow()
        sheet.owner = launcher
        XCTAssertNil(resolve(key: sheet, main: databaseA))
        XCTAssertNil(resolve(key: nil, main: nil))
    }

    private func resolve(key: NSWindow?, main: NSWindow?) -> Target? {
        let targets: [ObjectIdentifier: Target] = [
            ObjectIdentifier(databaseA): targetA, ObjectIdentifier(databaseB): targetB,
        ]
        return MacDatabaseCommandTargetResolver(keyWindow: key, mainWindow: main, launcherWindow: launcher,
            target: { targets[ObjectIdentifier($0)] }).resolve()
    }
}

@MainActor
private final class ResolverSheetWindow: NSWindow {
    weak var owner: NSWindow?
    override var sheetParent: NSWindow? { owner }
}
#endif
