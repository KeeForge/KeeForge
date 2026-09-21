import CryptoKit
import Foundation

/// A YubiKey whose slot holds `KDBXTestFixture.challengeResponse`'s HMAC-SHA1
/// secret, in variable-length mode (the `ykman otp chalresp` default): the key
/// drops trailing bytes equal to the last one before computing the HMAC.
enum YubiKeyEmulator {
    /// Mirrors `HMAC_SECRET` in `TestFixtures/generators/challenge_response.py`.
    static let fixtureSecret = Data("KeeForgeYubiKeyTest!".utf8)

    static func response(to challenge: Data, secret: Data = fixtureSecret) -> Data {
        var message = challenge
        if let last = message.last {
            while message.last == last {
                message.removeLast()
            }
        }
        return Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
    }
}
