#if KEEFORGE_DIRECT_DOWNLOAD
import Combine
import XCTest
@testable import KeeForge

@MainActor
final class SoftwareUpdateServiceTests: XCTestCase {
    func testReadinessTracksStartupAndUpdateCheckCompletion() async throws {
        let updater = FakeUpdaterReadiness()
        let service = SoftwareUpdateService(
            readiness: updater.publisher(for: \.canCheckForUpdates).eraseToAnyPublisher(),
            checkForUpdates: {},
            automaticChecks: true,
            setAutomaticChecks: { _ in }
        )
        XCTAssertFalse(service.canCheckForUpdates)

        updater.canCheckForUpdates = true
        try await waitForReadiness(true, in: service)

        updater.canCheckForUpdates = false
        try await waitForReadiness(false, in: service)

        updater.canCheckForUpdates = true
        try await waitForReadiness(true, in: service)
    }

    func testAutomaticChecksStartFromUpdaterAndWriteThrough() {
        var applied: [Bool] = []
        let service = SoftwareUpdateService(
            readiness: Empty().eraseToAnyPublisher(),
            checkForUpdates: {},
            automaticChecks: true,
            setAutomaticChecks: { applied.append($0) }
        )
        XCTAssertTrue(service.automaticallyChecksForUpdates)
        XCTAssertEqual(applied, [])

        service.automaticallyChecksForUpdates = false
        service.automaticallyChecksForUpdates = true
        XCTAssertEqual(applied, [false, true])
    }

    private func waitForReadiness(_ expected: Bool, in service: SoftwareUpdateService) async throws {
        let deadline = Date().addingTimeInterval(2)
        while service.canCheckForUpdates != expected, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.canCheckForUpdates, expected)
    }
}

private final class FakeUpdaterReadiness: NSObject {
    @objc dynamic var canCheckForUpdates = false
}
#endif
