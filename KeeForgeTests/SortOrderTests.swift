import XCTest
@testable import KeeForge

@MainActor
final class SortOrderTests: XCTestCase {
    private var viewModel: DatabaseViewModel!

    override func setUp() async throws {
        try await super.setUp()
        DatabaseListStore.clearAll()
        SharedVaultStore.clearBookmark()
        viewModel = try DatabaseViewModel(databaseReference: TestDatabaseSupport.makeReference(for: fixtureURL()))
        viewModel.sortAscending = true
    }

    override func tearDown() async throws {
        DatabaseListStore.clearAll()
        SharedVaultStore.clearBookmark()
        try await super.tearDown()
    }

    // MARK: - Entry Sorting

    func testSortEntriesByTitle() {
        viewModel.sortOrder = .title
        let entries = [
            KPEntry(title: "Zebra"),
            KPEntry(title: "Apple"),
            KPEntry(title: "Mango"),
        ]

        let sorted = viewModel.sortedEntries(entries)

        XCTAssertEqual(sorted.map(\.title), ["Apple", "Mango", "Zebra"])
    }

    func testSortEntriesByTitleIsCaseInsensitive() {
        viewModel.sortOrder = .title
        let entries = [
            KPEntry(title: "banana"),
            KPEntry(title: "Apple"),
            KPEntry(title: "cherry"),
        ]

        let sorted = viewModel.sortedEntries(entries)

        XCTAssertEqual(sorted.map(\.title), ["Apple", "banana", "cherry"])
    }

    func testSortEntriesByCreatedDate() {
        viewModel.sortOrder = .createdDate
        let old = Date(timeIntervalSince1970: 1_000_000)
        let mid = Date(timeIntervalSince1970: 2_000_000)
        let recent = Date(timeIntervalSince1970: 3_000_000)

        let entries = [
            KPEntry(title: "Mid", creationTime: mid),
            KPEntry(title: "Old", creationTime: old),
            KPEntry(title: "Recent", creationTime: recent),
        ]

        let sorted = viewModel.sortedEntries(entries)

        XCTAssertEqual(sorted.map(\.title), ["Old", "Mid", "Recent"])
    }

    func testSortEntriesByModifiedDateDescending() {
        viewModel.sortOrder = .modifiedDate
        viewModel.sortAscending = false
        let old = Date(timeIntervalSince1970: 1_000_000)
        let mid = Date(timeIntervalSince1970: 2_000_000)
        let recent = Date(timeIntervalSince1970: 3_000_000)

        let entries = [
            KPEntry(title: "Old", lastModificationTime: old),
            KPEntry(title: "Recent", lastModificationTime: recent),
            KPEntry(title: "Mid", lastModificationTime: mid),
        ]

        let sorted = viewModel.sortedEntries(entries)

        XCTAssertEqual(sorted.map(\.title), ["Recent", "Mid", "Old"])
    }

    func testSortEntriesWithNilDates() {
        viewModel.sortOrder = .createdDate
        let known = Date(timeIntervalSince1970: 1_000_000)

        let entries = [
            KPEntry(title: "NoDate"),
            KPEntry(title: "HasDate", creationTime: known),
        ]

        let sorted = viewModel.sortedEntries(entries)

        XCTAssertEqual(sorted.map(\.title), ["NoDate", "HasDate"])
    }

    // MARK: - Group Sorting

    func testSortGroupsByTitle() {
        viewModel.sortOrder = .title
        let groups = [
            KPGroup(name: "Work"),
            KPGroup(name: "Banking"),
            KPGroup(name: "Social"),
        ]

        let sorted = viewModel.sortedGroups(groups)

        XCTAssertEqual(sorted.map(\.name), ["Banking", "Social", "Work"])
    }

    func testSortGroupsByCreatedDate() {
        viewModel.sortOrder = .createdDate
        let old = Date(timeIntervalSince1970: 1_000_000)
        let recent = Date(timeIntervalSince1970: 2_000_000)

        let groups = [
            KPGroup(name: "Recent", creationTime: recent),
            KPGroup(name: "Old", creationTime: old),
        ]

        let sorted = viewModel.sortedGroups(groups)

        XCTAssertEqual(sorted.map(\.name), ["Old", "Recent"])
    }

    func testSortGroupsByModifiedDateDescending() {
        viewModel.sortOrder = .modifiedDate
        viewModel.sortAscending = false
        let old = Date(timeIntervalSince1970: 1_000_000)
        let recent = Date(timeIntervalSince1970: 2_000_000)

        let groups = [
            KPGroup(name: "Old", lastModificationTime: old),
            KPGroup(name: "Recent", lastModificationTime: recent),
        ]

        let sorted = viewModel.sortedGroups(groups)

        XCTAssertEqual(sorted.map(\.name), ["Recent", "Old"])
    }

    // MARK: - Recycle Bin Placement

    func testRecycleBinSortsFirstRegardlessOfSortOrder() async throws {
        let vm = try await makeKitchenSinkViewModel()
        let recycleBinID = try XCTUnwrap(vm.currentRootGroup?.recycleBinUUID)
        let groups = try XCTUnwrap(vm.visibleRootGroup?.groups)
        XCTAssertTrue(groups.contains { $0.id == recycleBinID })

        for order in [DatabaseViewModel.SortOrder.title, .createdDate, .modifiedDate] {
            for ascending in [true, false] {
                vm.sortOrder = order
                vm.sortAscending = ascending

                XCTAssertEqual(
                    vm.sortedGroups(groups).first?.id,
                    recycleBinID,
                    "Recycle Bin must lead the folder list for \(order) ascending=\(ascending)"
                )
            }
        }
    }

    func testRecycleBinPinningLeavesTheOtherGroupsSorted() async throws {
        let vm = try await makeKitchenSinkViewModel()
        let recycleBinID = try XCTUnwrap(vm.currentRootGroup?.recycleBinUUID)
        let groups = try XCTUnwrap(vm.visibleRootGroup?.groups)
        vm.sortOrder = .title
        vm.sortAscending = true

        let sorted = vm.sortedGroups(groups)

        XCTAssertEqual(sorted.count, groups.count)
        XCTAssertEqual(
            sorted.dropFirst().map(\.name),
            groups.filter { $0.id != recycleBinID }
                .map(\.name)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        )
    }

    func testGroupsWithoutARecycleBinKeepPlainSortOrder() {
        viewModel.sortOrder = .title
        let groups = [
            KPGroup(name: "Work"),
            KPGroup(name: "Banking"),
        ]

        XCTAssertEqual(viewModel.sortedGroups(groups).map(\.name), ["Banking", "Work"])
    }

    // MARK: - Persistence

    func testSortOrderPersistsToUserDefaults() {
        let key = "KeeForge.sortOrder"
        // Clean slate
        UserDefaults.standard.removeObject(forKey: key)

        let vm1 = try! DatabaseViewModel(databaseReference: TestDatabaseSupport.makeReference(for: fixtureURL()))
        vm1.sortOrder = .modifiedDate

        let vm2 = try! DatabaseViewModel(databaseReference: TestDatabaseSupport.makeReference(for: fixtureURL()))
        XCTAssertEqual(vm2.sortOrder, .modifiedDate)

        // Clean up
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Empty Input

    func testSortEmptyArrayReturnsEmpty() {
        XCTAssertTrue(viewModel.sortedEntries([]).isEmpty)
        XCTAssertTrue(viewModel.sortedGroups([]).isEmpty)
    }

    private func fixtureURL() throws -> URL {
        try TestDatabaseSupport.fixtureURL(named: "test", bundle: Bundle(for: SortOrderTests.self))
    }

    /// `kitchen-sink.kdbx` is the fixture that carries a real
    /// `Meta/RecycleBinUUID`, with root groups whose names put the bin in the
    /// middle of every sort order, so pinning it first is never a coincidence.
    private func makeKitchenSinkViewModel() async throws -> DatabaseViewModel {
        let url = try TestDatabaseSupport.fixtureURL(
            named: "kitchen-sink",
            bundle: Bundle(for: SortOrderTests.self)
        )
        let vm = try DatabaseViewModel(databaseReference: TestDatabaseSupport.makeReference(for: url))
        await vm.unlock(password: "testpassword123")
        return vm
    }
}
