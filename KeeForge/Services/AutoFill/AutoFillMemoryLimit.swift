import Foundation
#if os(iOS)
import os
#endif

/// Pre-flight check that keeps the AutoFill extension from being jetsam-killed
/// by a database whose key derivation cannot fit in the extension's budget.
///
/// AutoFill extensions run under a memory limit far below the app's, and Argon2
/// allocates its full memory parameter up front. A database configured with, say,
/// 1 GB of Argon2 memory takes the extension down before any error can surface,
/// which the user sees as AutoFill silently doing nothing while the same vault
/// opens fine in the app.
///
/// The KDF parameters live in the plaintext outer header, so the requirement is
/// known before a single byte is derived.
enum AutoFillMemoryLimit {
    /// Working set the parse needs on top of the KDF and the file bytes:
    /// decrypted payload, decompressed XML, and the node graph.
    ///
    /// A floor, not a prediction. The check exists to catch the case that is
    /// certain to fail — an Argon2 block larger than the whole remaining
    /// budget — without rejecting databases that would have opened.
    static let parseReserveBytes: UInt64 = 32 * 1024 * 1024

    struct BudgetExceeded: LocalizedError, Equatable {
        let requiredBytes: UInt64
        let availableBytes: UInt64

        var errorDescription: String? {
            String(localized: "This database needs about \(Self.byteText(requiredBytes)) of memory to unlock, more than the \(Self.byteText(availableBytes)) AutoFill is allowed to use. Open the entry in the KeeForge app, or lower the database's Argon2 memory setting in a desktop KeePass app.")
        }

        private static func byteText(_ bytes: UInt64) -> String {
            Int64(clamping: bytes).formatted(.byteCount(style: .memory))
        }
    }

    /// Bytes this process may still allocate before the system terminates it.
    ///
    /// `os_proc_available_memory` reports 0 for a process the system does not
    /// hold to a memory limit, which `check` reads as "unlimited" and skips.
    /// It is `API_UNAVAILABLE(macos)`, and macOS credential providers are not
    /// held to the iOS extension limit, so the check does not apply there.
    static func remainingBytes() -> UInt64 {
        #if os(iOS)
        return UInt64(clamping: os_proc_available_memory())
        #else
        return 0
        #endif
    }

    /// Throws `BudgetExceeded` when unlocking `summary` cannot fit in `remainingBytes`.
    ///
    /// `databaseByteCount` is counted again on top of the already-loaded file
    /// because the parse holds a decrypted copy of the payload alongside it.
    static func check(
        databaseByteCount: Int,
        summary: KDBXFileSummary,
        remainingBytes: UInt64
    ) throws {
        guard remainingBytes > 0 else { return }

        let required = saturatingSum(
            kdfMemoryBytes(for: summary.keyDerivation),
            UInt64(clamping: databaseByteCount),
            parseReserveBytes
        )

        guard required > remainingBytes else { return }
        throw BudgetExceeded(requiredBytes: required, availableBytes: remainingBytes)
    }

    /// The header's memory parameter is attacker-controlled and is not range-checked
    /// until `KDBXParser.deriveKey`, so summing it must not be able to trap here.
    private static func saturatingSum(_ values: UInt64...) -> UInt64 {
        values.reduce(UInt64.zero) { partial, value in
            let (sum, overflowed) = partial.addingReportingOverflow(value)
            return overflowed ? .max : sum
        }
    }

    /// AES-KDF is bounded by rounds, not memory, so it contributes nothing here.
    private static func kdfMemoryBytes(for keyDerivation: KDBXFileSummary.KeyDerivation) -> UInt64 {
        switch keyDerivation {
        case .argon2d(_, let memoryBytes, _), .argon2id(_, let memoryBytes, _):
            memoryBytes
        case .aesKDF, .unknown:
            0
        }
    }
}
