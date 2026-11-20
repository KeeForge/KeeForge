#if os(macOS)
import Foundation
import Security
@testable import KeeForge

final class FakeBrowserBridgeKeychain: BrowserBridgeKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var creationCount = 0
    private var deletionCount = 0
    private var shouldFail = false
    var data: Data? { lock.withLock { stored } }
    var creations: Int { lock.withLock { creationCount } }
    var deletions: Int { lock.withLock { deletionCount } }
    var fails: Bool {
        get { lock.withLock { shouldFail } }
        set { lock.withLock { shouldFail = newValue } }
    }
    func readPrivateKey() throws -> Data? {
        try lock.withLock {
            if shouldFail { throw BrowserPairingStoreError.keychain(errSecInteractionNotAllowed) }
            return stored
        }
    }
    func createPrivateKey(_ data: Data) throws {
        try lock.withLock {
            if shouldFail { throw BrowserPairingStoreError.keychain(errSecInteractionNotAllowed) }
            stored = data
            creationCount += 1
        }
    }
    func deletePrivateKey() throws {
        try lock.withLock {
            if shouldFail { throw BrowserPairingStoreError.keychain(errSecInteractionNotAllowed) }
            stored = nil
            deletionCount += 1
        }
    }
}
#endif
