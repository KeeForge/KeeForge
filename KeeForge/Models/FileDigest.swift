import CryptoKit
import Foundation

/// Content hashes for change detection and cache identity.
enum FileDigest {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func sha512(_ data: Data) -> Data {
        Data(SHA512.hash(data: data))
    }
}
