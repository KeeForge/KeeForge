#if os(macOS)
import AppKit
import XCTest
@testable import KeeForge

@MainActor
final class MacGroupPickerModelTests: XCTestCase {
    func testRowsDepthCurrentAndExcludedSubtreesAndDoubleClick() async throws {
        let database = try await makeDatabase()
        defer { database.lockRequest(force: true) }
        let root = try XCTUnwrap(database.visibleRootGroup)
        let work = try XCTUnwrap(root.groups.first { $0.name == "Work" })
        let social = try XCTUnwrap(root.groups.first { $0.name == "Social" })
        let entry = try XCTUnwrap(social.entries.first)
        try database.deleteEntry(try XCTUnwrap(work.entries.first).id, sendToRecycleBin: true)
        let bin = try XCTUnwrap(database.recycleBinGroup)
        let model = MacGroupPickerModel(purpose: .move(.entry(entry.id)), database: database)
        XCTAssertEqual(model.rows.first?.id, root.id)
        XCTAssertEqual(model.rows.first?.depth, 0)
        XCTAssertEqual(model.rows.first { $0.id == social.id }?.depth, 1)
        XCTAssertTrue(model.rows.first { $0.id == social.id }?.isCurrent == true)
        XCTAssertFalse(model.rows.first { $0.id == social.id }?.isSelectable == true)
        XCTAssertFalse(model.rows.contains { $0.id == bin.id })
        XCTAssertFalse(model.canConfirm)
        XCTAssertNil(model.confirmOnDoubleClick(social.id))
        XCTAssertNil(model.confirmOnDoubleClick(UUID()))
        XCTAssertEqual(model.confirmOnDoubleClick(work.id), work.id)
        XCTAssertTrue(model.canConfirm)
        XCTAssertEqual(model.currentPath, "Social")
        try database.createGroup(named: "Nested", in: work.id)
        let nestedID = try XCTUnwrap(database.group(withID: work.id)?.groups.first { $0.name == "Nested" }).id
        let groupModel = MacGroupPickerModel(purpose: .move(.group(work.id)), database: database)
        XCTAssertFalse(groupModel.rows.contains { $0.id == work.id })
        XCTAssertFalse(groupModel.rows.contains { $0.id == nestedID })
        let restore = MacGroupPickerModel(purpose: .move(.restore(.entry(try XCTUnwrap(bin.entries.first).id))), database: database)
        XCTAssertEqual(restore.title, String(localized: "Restore to Group"))
    }

    func testNativeOutlineExpandsTreeAndDisablesCurrentRow() async throws {
        let database = try await makeDatabase()
        defer { database.lockRequest(force: true) }
        let rootID = try XCTUnwrap(database.visibleRootGroupID)
        let model = MacGroupPickerModel(purpose: .autoFillDestination, database: database, current: rootID)
        let sheet = MacGroupPickerSheet(model: model)
        _ = sheet.view
        XCTAssertEqual(sheet.outline.numberOfRows, model.rows.count)
        let current = try XCTUnwrap(sheet.outline.item(atRow: 0))
        XCTAssertFalse(sheet.outlineView(sheet.outline, shouldSelectItem: current))
        XCTAssertEqual(model.title, String(localized: "Select Group"))
    }

    private func makeDatabase() async throws -> DatabaseViewModel {
        let url = try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: Self.self))
        let database = DatabaseViewModel(databaseReference: try TestDatabaseSupport.makeReference(for: url, autoFillEnabled: false),
            quickUnlockKeyPersistOperation: { _, _, _ in false }, storedKeyPresenceCheck: { _ in false })
        await database.unlock(password: "testpassword123")
        XCTAssertEqual(database.state, .unlocked)
        return database
    }
}
#endif
