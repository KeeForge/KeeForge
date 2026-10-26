import Foundation
import XCTest

/// The unit-test bundle's principal class (`NSPrincipalClass` in `project.yml`),
/// instantiated before any test runs.
@objc(KeeForgeTestPrincipal)
final class KeeForgeTestPrincipal: NSObject {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(BundledFixtureGuard())
    }
}

/// Fails the test that changes a bundled fixture and puts the original back,
/// so a test that saves to the bundle copy cannot break later tests, which
/// run in a different order on each CI system.
final class BundledFixtureGuard: NSObject, XCTestObservation {
    private static let fixtureExtensions: Set<String> = ["kdbx", "key", "keyx"]
    private var originals: [URL: Data] = [:]

    func testBundleWillStart(_ testBundle: Bundle) {
        guard let root = testBundle.resourceURL,
              let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in files where Self.fixtureExtensions.contains(url.pathExtension) {
            originals[url] = try? Data(contentsOf: url)
        }
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        let originals = originals
        testCase.addTeardownBlock {
            for (url, original) in originals.sorted(by: { $0.key.path < $1.key.path })
            where (try? Data(contentsOf: url)) != original {
                XCTFail("Bundled fixture \(url.lastPathComponent) was modified; save to a temporary copy instead")
                try? original.write(to: url)
            }
        }
    }
}
