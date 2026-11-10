import Foundation
import KDBXKit

// KDBXKit throws plain errors; KeeForge owns their user-facing text.

extension KDBXContainer.ParseError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSignature: String(localized: "Not a valid KDBX file")
        case .headerHashMismatch: String(localized: "The database header is damaged.")
        case .decompressedPayloadTooLarge: String(localized: "This database is too large for KeeForge to open.")
        case .unsupportedVersion:
            String(localized: "This database uses an older KeePass format that KeeForge does not support yet.")
        case .truncatedFile: String(localized: "File is truncated")
        case .invalidBlockHMAC: String(localized: "Block HMAC invalid — wrong password or corrupted file")
        case .invalidLegacyBlockHash: String(localized: "The database appears corrupted or incomplete.")
        case .invalidStreamStartBytes: String(localized: "Decryption failed — wrong password?")
        case .unsupportedProtectedFieldStream: String(localized: "This database uses an unsupported protected-field stream.")
        case .malformedVariantMap: String(localized: "Malformed variant map in header")
        case .kdfParameterOutOfRange(let p): String(localized: "KDF parameter out of range: \(p)")
        case .kdfResourceLimitExceeded(let iterations, let memoryBytes, let parallelism):
            // Same formatter as AutoFillMemoryLimit.BudgetExceeded so the two
            // Argon2 memory errors render consistently.
            String(localized: "This database's key derivation settings (\(Int64(clamping: memoryBytes).formatted(.byteCount(style: .memory))) of memory × \(String(iterations)) iterations, \(String(parallelism)) threads) exceed what this app can safely run. Lower the database's Argon2 settings in a desktop KeePass app and save it, then try again.")
        }
    }
}

extension KDBXCrypto.CryptoError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidKey: String(localized: "Invalid master key")
        case .encryptionFailed: String(localized: "Encryption failed")
        case .decryptionFailed: String(localized: "Decryption failed — wrong password?")
        case .hmacMismatch: String(localized: "HMAC verification failed — file corrupted or wrong password")
        case .unsupportedCipher(let uuid): String(localized: "Unsupported cipher: \(uuid.hexString)")
        case .unsupportedKDF(.missingUUID): String(localized: "The database is missing key derivation metadata.")
        case .unsupportedKDF(.missingSalt): String(localized: "The database is missing key derivation salt data.")
        case .unsupportedKDF(.unknownUUID(let uuid)): String(localized: "Unsupported key derivation function: \(uuid.hexString)")
        case .compressionFailed: String(localized: "Compression failed")
        case .decompressionFailed: String(localized: "Decompression failed")
        }
    }
}

extension KDBXContainerWriter.WriteError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSourceFormat:
            String(localized: "Saving legacy KDBX 3.1 databases is not supported yet.")
        case .unsupportedInnerRandomStream(let streamID):
            String(localized: "Unsupported inner random stream: \(streamID)")
        case .unsupportedCompression(let compressionFlags):
            String(localized: "Unsupported compression mode: \(compressionFlags)")
        case .payloadTooLarge:
            String(localized: "The database would be too large for KeeForge to open again, so it was not saved.")
        case .randomGenerationFailed:
            String(localized: "Secure random data could not be generated.")
        }
    }
}

extension KDBXKeyFile.KeyFileError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyKeyFile: String(localized: "Key file is empty")
        case .xmlKeyDataInvalid: String(localized: "Key file XML contains invalid key data")
        case .xmlHashMismatch: String(localized: "Key file hash verification failed — file may be corrupted")
        case .xmlVersionUnsupported: String(localized: "This key file uses a version KeeForge does not support.")
        }
    }
}
