import Foundation
import Security

enum SecureRandom {
    enum RandomError: Error, LocalizedError {
        case generationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .generationFailed:
                "Secure random data could not be generated."
            }
        }
    }

    static func data(count: Int) throws -> Data {
        guard count >= 0 else {
            throw RandomError.generationFailed(errSecParam)
        }

        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw RandomError.generationFailed(status)
        }
        return Data(bytes)
    }
}
