import Foundation
import LocalAuthentication

struct DatabaseOpenFailure: Equatable, Sendable {
    enum Category: String, Sendable {
        case authentication
        case biometric
        case fileAccess = "file_access"
        case cloud
        case unsupportedFormat = "unsupported_format"
        case unexpected
    }

    let title: String
    let summary: String
    let technicalDetails: String
    let errorCode: String
    let category: Category
    let countsTowardFailedAttempts: Bool
    let canChooseDifferentFile: Bool

    var isAuthenticationFailure: Bool {
        category == .authentication
    }

    var privacyNote: String {
        "Database contents, passwords, key files, and raw vault files are never included."
    }

    var copyableDetails: String {
        """
        \(title)

        \(summary)

        Error Code: \(errorCode)
        Category: \(category.rawValue)
        Technical Details: \(technicalDetails)

        Privacy: \(privacyNote)
        """
    }

    static func classify(_ error: Error, isCloudBacked: Bool) -> DatabaseOpenFailure {
        if let cloudError = error as? CloudProviderError {
            return fromCloudError(cloudError)
        }

        if let cryptoError = error as? KDBXCrypto.CryptoError {
            return fromCryptoError(cryptoError)
        }

        if let parseError = error as? KDBXParser.ParseError {
            return fromParseError(parseError)
        }

        if let biometricFailure = fromBiometricError(error) {
            return biometricFailure
        }

        if let cocoaFailure = fromCocoaError(error) {
            return cocoaFailure
        }

        return DatabaseOpenFailure(
            title: isCloudBacked ? "Couldn't Open Cloud Database" : "Couldn't Open Database",
            summary: "KeeForge hit an unexpected problem while opening this database.",
            technicalDetails: technicalDetails(for: error),
            errorCode: isCloudBacked ? "cloud.unexpected" : "open.unexpected",
            category: isCloudBacked ? .cloud : .unexpected,
            countsTowardFailedAttempts: false,
            canChooseDifferentFile: !isCloudBacked
        )
    }

    private static func fromCryptoError(_ error: KDBXCrypto.CryptoError) -> DatabaseOpenFailure {
        switch error {
        case .invalidKey, .decryptionFailed, .hmacMismatch:
            return DatabaseOpenFailure(
                title: "Couldn't Unlock Database",
                summary: "The password or key file didn't unlock this database. If you're sure they are correct, the file may be corrupted.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "auth.invalid_credentials",
                category: .authentication,
                countsTowardFailedAttempts: true,
                canChooseDifferentFile: false
            )
        case .unsupportedCipher:
            return DatabaseOpenFailure(
                title: "Unsupported Database Format",
                summary: "This database uses an encryption format that KeeForge does not support yet.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "format.unsupported_cipher",
                category: .unsupportedFormat,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: true
            )
        case .unsupportedKDF:
            return DatabaseOpenFailure(
                title: "Unsupported Database Format",
                summary: "This database uses a key-derivation format that KeeForge does not support yet.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "format.unsupported_kdf",
                category: .unsupportedFormat,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: true
            )
        case .encryptionFailed, .compressionFailed, .decompressionFailed:
            return DatabaseOpenFailure(
                title: "Couldn't Open Database",
                summary: "KeeForge hit an unexpected problem while processing this database.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "open.crypto_failed",
                category: .unexpected,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: true
            )
        }
    }

    private static func fromParseError(_ error: KDBXParser.ParseError) -> DatabaseOpenFailure {
        switch error {
        case .invalidBlockHMAC, .invalidStreamStartBytes:
            return DatabaseOpenFailure(
                title: "Couldn't Unlock Database",
                summary: "The password or key file didn't unlock this database. If you're sure they are correct, the file may be corrupted.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "auth.invalid_credentials",
                category: .authentication,
                countsTowardFailedAttempts: true,
                canChooseDifferentFile: false
            )
        case .unsupportedVersion:
            return DatabaseOpenFailure(
                title: "Unsupported Database Format",
                summary: "This database uses a KeePass format that KeeForge does not support yet.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "format.unsupported_version",
                category: .unsupportedFormat,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: true
            )
        case .unsupportedProtectedFieldStream:
            return DatabaseOpenFailure(
                title: "Unsupported Database Format",
                summary: "This database uses a protected-field format that KeeForge does not support yet.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "format.unsupported_protected_stream",
                category: .unsupportedFormat,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: true
            )
        case .invalidSignature:
            return DatabaseOpenFailure(
                title: "Not a KeePass Database",
                summary: "KeeForge couldn't recognize this file as a valid KDBX database.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "format.invalid_signature",
                category: .unsupportedFormat,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: true
            )
        default:
            return DatabaseOpenFailure(
                title: "Couldn't Open Database",
                summary: "KeeForge couldn't finish reading this database file.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "open.parse_failed",
                category: .unexpected,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: true
            )
        }
    }

    private static func fromCloudError(_ error: CloudProviderError) -> DatabaseOpenFailure {
        switch error {
        case .notAuthenticated:
            return DatabaseOpenFailure(
                title: "Reconnect Cloud Account",
                summary: "KeeForge needs you to reconnect this cloud account before it can open the database.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "cloud.not_authenticated",
                category: .cloud,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: false
            )
        case .networkUnavailable:
            return DatabaseOpenFailure(
                title: "Network Unavailable",
                summary: "KeeForge couldn't reach the cloud provider. Try again when your connection is back.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "cloud.network_unavailable",
                category: .cloud,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: false
            )
        case .fileNotFound:
            return DatabaseOpenFailure(
                title: "Cloud Database Unavailable",
                summary: "KeeForge couldn't find this cloud database. It may have moved, been deleted, or the account may need to reconnect.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "cloud.file_not_found",
                category: .cloud,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: false
            )
        case .authenticationCancelled:
            return DatabaseOpenFailure(
                title: "Cloud Sign-In Cancelled",
                summary: "The cloud sign-in flow was cancelled before KeeForge could open the database.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "cloud.authentication_cancelled",
                category: .cloud,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: false
            )
        case .invalidConfiguration:
            return DatabaseOpenFailure(
                title: "Cloud Sync Not Configured",
                summary: "This build of KeeForge is missing the cloud sync configuration it needs to open that database.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "cloud.invalid_configuration",
                category: .cloud,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: false
            )
        case .writeScopeRequired:
            return DatabaseOpenFailure(
                title: "Reconnect Dropbox",
                summary: "KeeForge needs refreshed Dropbox access before it can continue with this database.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "cloud.write_scope_required",
                category: .cloud,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: false
            )
        case .conflict, .unknown:
            return DatabaseOpenFailure(
                title: "Couldn't Open Cloud Database",
                summary: "KeeForge hit an unexpected cloud-sync problem while opening this database.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "cloud.unexpected",
                category: .cloud,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: false
            )
        }
    }

    private static func fromBiometricError(_ error: Error) -> DatabaseOpenFailure? {
        let nsError = error as NSError
        guard nsError.domain == LAError.errorDomain,
              let code = LAError.Code(rawValue: nsError.code) else {
            return nil
        }

        let summary: String
        let errorCode: String

        switch code {
        case .userCancel, .appCancel, .systemCancel:
            summary = "Biometric unlock was cancelled before KeeForge could open the database."
            errorCode = "biometric.cancelled"
        case .authenticationFailed:
            summary = "Face ID or Touch ID didn't verify, so KeeForge could not continue unlocking."
            errorCode = "biometric.authentication_failed"
        case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout:
            summary = "Biometric unlock isn't available right now. You can still use your password and key file."
            errorCode = "biometric.unavailable"
        default:
            summary = "KeeForge couldn't finish the biometric unlock flow."
            errorCode = "biometric.unexpected"
        }

        return DatabaseOpenFailure(
            title: "Biometric Unlock Failed",
            summary: summary,
            technicalDetails: technicalDetails(for: error),
            errorCode: errorCode,
            category: .biometric,
            countsTowardFailedAttempts: false,
            canChooseDifferentFile: false
        )
    }

    private static func fromCocoaError(_ error: Error) -> DatabaseOpenFailure? {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else {
            return nil
        }
        let code = CocoaError.Code(rawValue: nsError.code)

        switch code {
        case .fileReadNoSuchFile:
            return DatabaseOpenFailure(
                title: "Database File Unavailable",
                summary: "KeeForge couldn't find the selected database file. It may have moved, been deleted, or the saved bookmark may need to be refreshed.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "file.not_found",
                category: .fileAccess,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: true
            )
        case .fileReadNoPermission:
            return DatabaseOpenFailure(
                title: "Database Permission Needed",
                summary: "KeeForge no longer has permission to read this database file. Choose it again from the database list to refresh access.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "file.permission_denied",
                category: .fileAccess,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: true
            )
        default:
            return DatabaseOpenFailure(
                title: "Couldn't Access Database File",
                summary: "KeeForge couldn't access the selected database file.",
                technicalDetails: technicalDetails(for: error),
                errorCode: "file.read_failed",
                category: .fileAccess,
                countsTowardFailedAttempts: false,
                canChooseDifferentFile: true
            )
        }
    }

    private static func technicalDetails(for error: Error) -> String {
        let nsError = error as NSError
        let sanitizedDescription = sanitized(error.localizedDescription)
        if sanitizedDescription.isEmpty {
            return "\(nsError.domain) (\(nsError.code))"
        }
        return "\(sanitizedDescription) [\(nsError.domain) \(nsError.code)]"
    }

    private static func sanitized(_ string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }

        let patterns = [
            #"file:\/\/[^\s]+"#,
            #"/(?:private|var|Users|Volumes|tmp)[^\s]*"#,
        ]

        let redacted = patterns.reduce(trimmed) { partialResult, pattern in
            partialResult.replacingOccurrences(
                of: pattern,
                with: "[redacted-path]",
                options: .regularExpression
            )
        }

        return redacted.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }
}
