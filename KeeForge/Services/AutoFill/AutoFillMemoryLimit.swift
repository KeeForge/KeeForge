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

    /// Throws `BudgetExceeded` when the key derivation alone cannot fit in
    /// `remainingBytes`.
    ///
    /// Deliberately only that. Argon2 takes its memory parameter as one
    /// allocation, so a parameter larger than what the process may still
    /// allocate is arithmetic, not estimation: that allocation cannot succeed,
    /// whatever else the unlock would have gone on to do.
    ///
    /// The decrypt and parse that follow need memory too, and this check
    /// deliberately does not price them. They belong to a later peak — the KDF
    /// block is freed before the payload is decompressed — so folding them in
    /// would compare against a budget that no single moment of the unlock ever
    /// faces, and would start refusing databases that open today. A false
    /// refusal breaks a vault that works; the bug it would be guarding against
    /// only breaks one that already fails.
    ///
    /// The caller has the file in memory before this runs, so `remainingBytes`
    /// already has the file's own bytes deducted — counting them again here
    /// would be double-counting, not caution.
    static func check(summary: KDBXFileSummary, remainingBytes: UInt64) throws {
        guard remainingBytes > 0 else { return }

        let required = kdfMemoryBytes(for: summary.keyDerivation)
        guard required > remainingBytes else { return }
        throw BudgetExceeded(requiredBytes: required, availableBytes: remainingBytes)
    }

    /// AES-KDF is bounded by rounds, not memory, so it contributes nothing here.
    ///
    /// The header's memory parameter is attacker-controlled and is not
    /// range-checked until `KDBXParser.deriveKey`; it is compared, never summed,
    /// so even `UInt64.max` reaches the comparison intact rather than trapping.
    private static func kdfMemoryBytes(for keyDerivation: KDBXFileSummary.KeyDerivation) -> UInt64 {
        switch keyDerivation {
        case .argon2d(_, let memoryBytes, _), .argon2id(_, let memoryBytes, _):
            memoryBytes
        case .aesKDF, .unknown:
            0
        }
    }
}
