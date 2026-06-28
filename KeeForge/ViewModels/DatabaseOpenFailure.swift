import Foundation
import LocalAuthentication
import UIKit

struct DatabaseOpenDiagnostics: Equatable, Sendable {
    enum UnlockMethod: String, Sendable {
        case password
        case biometrics
    }

    let lines: [String]

    var details: String {
        guard lines.isEmpty == false else { return "" }
        return (["Diagnostics:"] + lines.map { "- \($0)" }).joined(separator: "\n")
    }

    @MainActor
    static func make(
        reference: DatabaseReference,
        unlockMethod: UnlockMethod,
        passwordSupplied: Bool,
        keyFileSupplied: Bool,
        failedAttemptsBeforeAttempt: Int,
        encryptedData: Data?,
        cloudSyncStatus: CloudSyncResolution.Status?
    ) -> DatabaseOpenDiagnostics {
        var lines = [
            "Unlock Method: \(unlockMethod.rawValue)",
            "Password Supplied: \(yesNo(passwordSupplied))",
            "Key File Supplied: \(yesNo(keyFileSupplied))",
            "Associated Key File Configured: \(yesNo(reference.hasAssociatedKeyFile))",
            "Failed Attempts Before Attempt: \(failedAttemptsBeforeAttempt)",
            "Database Source: \(reference.isCloudBacked ? "cloud" : "local")",
            "Database Read Only: \(yesNo(reference.isReadOnly))",
        ]

        if let metadata = reference.cloudSyncMetadata {
            lines.append("Cloud Provider: \(metadata.providerKind?.displayName ?? metadata.provider)")
            lines.append("Cloud Sync Status: \(cloudStatusDescription(cloudSyncStatus))")
            lines.append("Remote Revision Prefix: \(prefix(metadata.remoteRev))")
            lines.append("Remote Content Hash Prefix: \(prefix(metadata.remoteContentHash))")
            lines.append("Last Synced At: \(dateDescription(metadata.lastSyncedAt))")
        } else {
            lines.append("Cloud Provider: n/a")
            lines.append("Cloud Sync Status: n/a")
            lines.append("Remote Revision Prefix: n/a")
            lines.append("Remote Content Hash Prefix: n/a")
            lines.append("Last Synced At: n/a")
        }

        if let encryptedData {
            lines.append("Encrypted File Bytes: \(encryptedData.count)")
            lines.append("Encrypted File SHA-256 Prefix: \(String(KDBXCrypto.sha256(encryptedData).hexString.prefix(16)))")
            lines.append("KDBX Header: \(headerSummary(for: encryptedData))")
        } else {
            lines.append("Encrypted File Bytes: unavailable")
            lines.append("Encrypted File SHA-256 Prefix: unavailable")
            lines.append("KDBX Header: unavailable")
        }

        lines.append("App Version: \(appVersion)")
        lines.append("Build: \(buildNumber)")
        lines.append("OS Version: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        lines.append("Device Model: \(deviceModelIdentifier)")

        return DatabaseOpenDiagnostics(lines: lines)
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private static func prefix(_ value: String?) -> String {
        guard let value, value.isEmpty == false else { return "n/a" }
        return String(value.prefix(12))
    }

    private static func dateDescription(_ date: Date?) -> String {
        guard let date else { return "n/a" }
        return ISO8601DateFormatter().string(from: date)
    }

    private static func cloudStatusDescription(_ status: CloudSyncResolution.Status?) -> String {
        guard let status else { return "unavailable" }
        switch status {
        case .current:
            return "current"
        case .downloaded:
            return "downloaded"
        case .offlineCached:
            return "offline_cached"
        case .disconnectedCached:
            return "disconnected_cached"
        case .cachedWithError:
            return "cached_with_error"
        }
    }

    private static func headerSummary(for data: Data) -> String {
        do {
            let version = try KDBXParser.parseFileVersion(from: data)
            switch version {
            case .kdbx3_1:
                let header = try KDBXParser.parseKDBX3Header(from: data)
                return [
                    "version=\(formatVersionDescription(header.formatVersion))",
                    "cipher=\(cipherDescription(header.cipherID))",
                    "compression=\(compressionDescription(header.compressionFlags))",
                    "kdf=AES-KDF rounds=\(header.transformRounds)",
                    "protectedStream=\(protectedStreamDescription(header.innerRandomStreamID))",
                ].joined(separator: ", ")
            case .kdbx4:
                var reader = DataReader(data: data)
                let parsedVersion = try KDBXParser.parseVersion(from: &reader)
                let header = try KDBXParser.parseHeader(&reader)
                return [
                    "version=\(formatVersionDescription(parsedVersion))",
                    "cipher=\(cipherDescription(header.cipherID))",
                    "compression=\(compressionDescription(header.compressionFlags))",
                    "kdf=\(kdfDescription(header.kdfParameters))",
                    "protectedStream=unavailable",
                ].joined(separator: ", ")
            }
        } catch {
            return "unavailable (\(DatabaseOpenFailure.sanitized(error.localizedDescription)))"
        }
    }

    private static func formatVersionDescription(_ version: KDBXParser.FileVersion) -> String {
        switch version {
        case .kdbx3_1:
            return "KDBX 3.1"
        case .kdbx4(let minor):
            return "KDBX 4.\(minor)"
        }
    }

    private static func cipherDescription(_ cipherID: Data) -> String {
        if cipherID == KDBXParser.aesCipherUUID {
            return "AES-256"
        }
        if cipherID == KDBXParser.chachaCipherUUID {
            return "ChaCha20-Poly1305"
        }
        return "unknown"
    }

    private static func compressionDescription(_ compressionFlags: UInt32) -> String {
        switch compressionFlags {
        case 0:
            return "none"
        case 1:
            return "gzip"
        default:
            return "unknown(\(compressionFlags))"
        }
    }

    private static func kdfDescription(_ parameters: [String: Any]) -> String {
        guard let uuidData = parameters["$UUID"] as? Data else {
            return "unknown"
        }

        if uuidData == KDBXParser.aesKDFUUID {
            let rounds = (parameters["R"] as? UInt64) ?? 0
            return "AES-KDF rounds=\(rounds)"
        }

        if uuidData == KDBXParser.argon2dUUID || uuidData == KDBXParser.argon2idUUID {
            let name = uuidData == KDBXParser.argon2idUUID ? "Argon2id" : "Argon2d"
            let iterations = (parameters["I"] as? UInt64) ?? 3
            let memoryBytes = (parameters["M"] as? UInt64) ?? (64 * 1024 * 1024)
            let parallelism = (parameters["P"] as? UInt32) ?? 1
            let version = (parameters["V"] as? UInt32).map { " version=\($0)" } ?? ""
            return "\(name) iterations=\(iterations) memoryBytes=\(memoryBytes) parallelism=\(parallelism)\(version)"
        }

        return "unknown"
    }

    private static func protectedStreamDescription(_ streamID: UInt32) -> String {
        switch streamID {
        case KDBXParser.innerStreamNone:
            return "none(0)"
        case KDBXParser.innerStreamArcFourVariant:
            return "ArcFourVariant(1)"
        case KDBXParser.innerStreamSalsa20:
            return "Salsa20(2)"
        case KDBXParser.innerStreamChaCha20:
            return "ChaCha20(3)"
        default:
            return "unknown(\(streamID))"
        }
    }

    @MainActor
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    @MainActor
    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    private static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)

        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.compactMap { child -> String? in
            guard let value = child.value as? Int8, value != 0 else { return nil }
            return String(UnicodeScalar(UInt8(value)))
        }.joined()

        return identifier.isEmpty ? "unknown" : identifier
    }
}

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
    var diagnostics: DatabaseOpenDiagnostics? = nil

    var isAuthenticationFailure: Bool {
        category == .authentication
    }

    var privacyNote: String {
        "Database contents, passwords, key files, and raw vault files are never included. Visible diagnostics may include app/device metadata and short file hash prefixes."
    }

    var reportDetails: String {
        var components = [
            "Title: \(title)",
            "Summary: \(summary)",
            "Technical Details: \(technicalDetails)",
        ]

        if let diagnostics {
            components.append(diagnostics.details)
        }

        return components.joined(separator: "\n")
    }

    var copyableDetails: String {
        var components = [
            """
            \(title)

            \(summary)

            Error Code: \(errorCode)
            Category: \(category.rawValue)
            Technical Details: \(technicalDetails)
            """,
        ]

        if let diagnostics {
            components.append(diagnostics.details)
        }

        components.append("Privacy: \(privacyNote)")

        return components.joined(separator: "\n\n")
    }

    static func classify(
        _ error: Error,
        isCloudBacked: Bool,
        diagnostics: DatabaseOpenDiagnostics? = nil
    ) -> DatabaseOpenFailure {
        if let cloudError = error as? CloudProviderError {
            return fromCloudError(cloudError).attaching(diagnostics)
        }

        if let cryptoError = error as? KDBXCrypto.CryptoError {
            return fromCryptoError(cryptoError).attaching(diagnostics)
        }

        if let parseError = error as? KDBXParser.ParseError {
            return fromParseError(parseError).attaching(diagnostics)
        }

        if let biometricFailure = fromBiometricError(error) {
            return biometricFailure.attaching(diagnostics)
        }

        if let cocoaFailure = fromCocoaError(error) {
            return cocoaFailure.attaching(diagnostics)
        }

        return DatabaseOpenFailure(
            title: isCloudBacked ? "Couldn't Open Cloud Database" : "Couldn't Open Database",
            summary: "KeeForge hit an unexpected problem while opening this database.",
            technicalDetails: technicalDetails(for: error),
            errorCode: isCloudBacked ? "cloud.unexpected" : "open.unexpected",
            category: isCloudBacked ? .cloud : .unexpected,
            countsTowardFailedAttempts: false,
            canChooseDifferentFile: !isCloudBacked,
            diagnostics: diagnostics
        )
    }

    private func attaching(_ diagnostics: DatabaseOpenDiagnostics?) -> DatabaseOpenFailure {
        var copy = self
        copy.diagnostics = diagnostics
        return copy
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
                title: "Reconnect Cloud Account",
                summary: "KeeForge needs refreshed cloud access before it can continue with this database.",
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

    fileprivate static func sanitized(_ string: String) -> String {
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
