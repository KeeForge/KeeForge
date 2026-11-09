import Foundation
import KDBXKit

// KDBXKit throws plain errors; KeeForge owns their user-facing text.

extension KDBXContainer.ParseError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSignature: String(localized: "Not a valid KDBX file")
        case .unsupportedVersion:
            String(localized: "This database uses an older KeePass format that KeeForge does not support yet.")
        case .truncatedFile: String(localized: "File is truncated")
        case .headerFieldMissing(let f): String(localized: "Missing header field: \(f)")
        case .xmlParsingFailed: String(localized: "Failed to parse database XML")
        case .invalidBlockHMAC: String(localized: "Block HMAC invalid — wrong password or corrupted file")
        case .invalidLegacyBlockHash: String(localized: "The database appears corrupted or incomplete.")
        case .invalidStreamStartBytes: String(localized: "Decryption failed — wrong password?")
        case .innerHeaderInvalid: String(localized: "Invalid inner header")
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
        case .unsupportedCipher(let c): String(localized: "Unsupported cipher: \(c)")
        case .unsupportedKDF(let descriptor): String(localized: "Unsupported key derivation function: \(descriptor.userFacingDescription)")
        case .compressionFailed: String(localized: "Compression failed")
        case .decompressionFailed: String(localized: "Decompression failed")
        }
    }
}

extension KDFDescriptor {
    var userFacingDescription: String {
        switch identifier {
        case "missing UUID":
            String(localized: "The database is missing key derivation metadata.")
        case "missing salt":
            String(localized: "The database is missing key derivation salt data.")
        default:
            displayName
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
        case .unsupportedVariantMapValue(let key):
            String(localized: "Unsupported variant map value for key: \(key)")
        case .payloadTooLarge:
            String(localized: "The database would be too large for KeeForge to open again, so it was not saved.")
        case .randomGenerationFailed:
            String(localized: "Secure random data could not be generated.")
        }
    }
}

extension KeyFileProcessor.KeyFileError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyKeyFile: String(localized: "Key file is empty")
        case .xmlKeyDataInvalid: String(localized: "Key file XML contains invalid key data")
        case .xmlHashMismatch: String(localized: "Key file hash verification failed — file may be corrupted")
        }
    }
}
