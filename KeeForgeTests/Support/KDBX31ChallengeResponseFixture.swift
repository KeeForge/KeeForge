import CommonCrypto
import CryptoKit
import Foundation
import KDBXKit
@testable import KeeForge

/// `KDBXTestFixture.legacyKDBX31` re-keyed the way KeePassXC keys a KDBX 3.1
/// file with a YubiKey: the master seed, padded, is the challenge, and the
/// final key is `SHA256(masterSeed || SHA256(response) || transformedKey)`.
/// Only the AES-CBC payload is re-encrypted; the header is unchanged.
enum KDBX31ChallengeResponseFixture {
    static func data(in bundle: Bundle, secret: Data = YubiKeyEmulator.fixtureSecret) throws -> Data {
        let fixture = KDBXTestFixture.legacyKDBX31
        let original = try fixture.data(in: bundle)
        let header = try KDBXContainer.readHeader(from: original)
        guard header.cipher == .aes256CBC else { throw FixtureError.unexpectedCipher }

        let compositeKey = try KDBXCrypto.compositeKey(password: fixture.password, keyFileData: nil)
        let transformedKey = try KDBXKeyDerivation.deriveKey(
            compositeKey: compositeKey,
            parameters: header.kdfParameters,
            policy: .mainApp
        )
        let response = YubiKeyEmulator.response(to: try ChallengeResponseKey.challenge(forSalt: header.masterSeed), secret: secret)
        let oldKey = Data(SHA256.hash(data: header.masterSeed + transformedKey))
        let newKey = Data(SHA256.hash(data: header.masterSeed + Data(SHA256.hash(data: response)) + transformedKey))

        let payload = original.subdata(in: header.headerData.count..<original.count)
        let plaintext = try crypt(CCOperation(kCCDecrypt), payload, key: oldKey, iv: header.encryptionIV)
        return header.headerData + (try crypt(CCOperation(kCCEncrypt), plaintext, key: newKey, iv: header.encryptionIV))
    }

    enum FixtureError: Error {
        case unexpectedCipher
        case cryptFailed(CCCryptorStatus)
    }

    private static func crypt(_ operation: CCOperation, _ input: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inputBytes.baseAddress, input.count,
                            outputBytes.baseAddress, outputCapacity, &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw FixtureError.cryptFailed(status) }
        return output.prefix(written)
    }
}
