import CryptoKit
import Foundation
@testable import KeeForge

extension TOTPGenerator {
    /// The secret bytes `parameters(for:sessionKey:)` resolves, for assertions.
    static func decryptedSecret(config: TOTPConfig, sessionKey: SymmetricKey) -> Data? {
        parameters(for: config, sessionKey: sessionKey)?.secret.withUnsafeBytes { Data($0) }
    }
}
