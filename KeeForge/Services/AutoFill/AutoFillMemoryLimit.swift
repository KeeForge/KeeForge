import Foundation
#if os(iOS)
import os
#endif

/// Pre-flight check that keeps the AutoFill extension from being jetsam-killed
/// by a database whose key derivation cannot fit in the extension's budget.
///
/// AutoFill extensions run under a memory limit far below the app's, and Argon2
/// allocates its full memory parameter up front — a large enough setting kills
/// the extension before any error can surface (#57). The KDF parameters live in
/// the plaintext outer header, so the requirement is known before deriving.
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
    /// `os_proc_available_memory` reports 0 for a process under no memory limit,
    /// which `check` reads as "unlimited". It is also `API_UNAVAILABLE(macos)`,
    /// where credential providers are not held to the iOS extension limit.
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
    /// Deliberately only the KDF: Argon2 takes its memory parameter as one
    /// allocation, so exceeding the budget is arithmetic, not estimation. The
    /// decrypt and parse that follow are a later peak (the KDF block is freed
    /// first), and the file's own bytes are already deducted from
    /// `remainingBytes` — pricing either in would refuse vaults that open
    /// today, and a false refusal breaks a working vault.
    static func check(summary: KDBXFileSummary, remainingBytes: UInt64) throws {
        guard remainingBytes > 0 else { return }

        let required = kdfMemoryBytes(for: summary.keyDerivation)
        guard required > remainingBytes else { return }
        throw BudgetExceeded(requiredBytes: required, availableBytes: remainingBytes)
    }

    /// AES-KDF is bounded by rounds, not memory, so it contributes nothing.
    /// The header's memory parameter is unvalidated until `KDBXParser.deriveKey`;
    /// it is compared, never summed, so even `UInt64.max` cannot trap.
    private static func kdfMemoryBytes(for keyDerivation: KDBXFileSummary.KeyDerivation) -> UInt64 {
        switch keyDerivation {
        case .argon2d(_, let memoryBytes, _), .argon2id(_, let memoryBytes, _):
            memoryBytes
        case .aesKDF, .unknown:
            0
        }
    }
}
