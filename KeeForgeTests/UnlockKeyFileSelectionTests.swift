import XCTest
@testable import KeeForge

@MainActor
final class UnlockKeyFileSelectionTests: XCTestCase {
    func testReadsTheSelectedFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let expected = Data([1, 2, 3, 4])
        try expected.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let selection = UnlockKeyFileSelection()

        let readResult = await selection.read(url: url)
        let result = try XCTUnwrap(readResult)

        XCTAssertEqual(try result.get(), expected)
        XCTAssertFalse(selection.isLoading)
    }

    func testReadFailureRemainsAvailableForThePickerAlert() async throws {
        let selection = UnlockKeyFileSelection { _ in throw CocoaError(.fileReadNoSuchFile) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let readResult = await selection.read(url: url)
        let result = try XCTUnwrap(readResult)

        guard case .failure(let error) = result else {
            return XCTFail("Expected the file read error")
        }
        XCTAssertNotNil(DocumentPickerService.pickerFailureAlert(for: error))
        XCTAssertFalse(selection.isLoading)
    }

    func testCancelledSelectionIgnoresLateReadCompletion() async {
        let suspension = SelectedKeyFileSuspension()
        let selection = UnlockKeyFileSelection { _ in await suspension.wait() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let loading = Task { await selection.read(url: url) }
        await suspension.waitUntilStarted()
        XCTAssertTrue(selection.isLoading)
        selection.cancel()
        await suspension.resolve(Data([1]))

        let result = await loading.value
        XCTAssertNil(result)
        XCTAssertFalse(selection.isLoading)
    }

    func testReplacedSelectionCannotFinishTheNewSelection() async throws {
        let suspension = SelectedKeyFileSuspension()
        let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent("first.key")
        let secondURL = FileManager.default.temporaryDirectory.appendingPathComponent("second.key")
        let expected = Data([2])
        let selection = UnlockKeyFileSelection { url in
            if url == firstURL { return await suspension.wait() }
            return expected
        }
        let firstLoad = Task { await selection.read(url: firstURL) }
        await suspension.waitUntilStarted()
        let secondResult = await selection.read(url: secondURL)
        await suspension.resolve(Data([1]))

        let firstResult = await firstLoad.value
        XCTAssertNil(firstResult)
        XCTAssertEqual(try XCTUnwrap(secondResult).get(), expected)
        XCTAssertFalse(selection.isLoading)
    }

    func testTaskCancellationDiscardsTheReadWithoutStrandingLoadingState() async {
        let suspension = SelectedKeyFileSuspension()
        let selection = UnlockKeyFileSelection { _ in await suspension.wait() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let loading = Task { await selection.read(url: url) }
        await suspension.waitUntilStarted()
        loading.cancel()
        await suspension.resolve(Data([1]))

        let result = await loading.value
        XCTAssertNil(result)
        XCTAssertFalse(selection.isLoading)
    }
}

private actor SelectedKeyFileSuspension {
    private var continuation: CheckedContinuation<Data, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func wait() async -> Data {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            hasStarted = true
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resolve(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}
