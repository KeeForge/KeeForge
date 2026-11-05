import Foundation

/// Budget for executing an attacker-controlled KDF configuration.
/// Format validity is checked separately; this bounds local resource use only.
///
/// KeeForge's own creation default (64 MiB × 10 iterations = 640 MiB total
/// work) must comfortably pass both policies. Constants are engineering
/// estimates pending on-device benchmarking (issue #74).
struct KDFExecutionPolicy: Sendable, Equatable {
    /// Upper bound on the Argon2 memory parameter (peak allocation).
    let maxPeakMemoryBytes: UInt64
    /// Upper bound on memory × iterations (total bytes processed), the real CPU cost proxy.
    let maxTotalWorkBytes: UInt64
    /// Upper bound on Argon2 lanes/threads.
    let maxParallelism: UInt32

    /// Work and parallelism bounds are identical across contexts: they exist to
    /// stop hostile headers from soaking CPU, and a slow-but-survivable unlock
    /// must not be refused in one context that the other runs (a vault is
    /// rejected only when certain to fail, never for being slow). The app's
    /// peak matches the widest memory the parser has ever accepted, so no
    /// previously-openable vault is stranded by this policy.
    static let mainApp = KDFExecutionPolicy(
        maxPeakMemoryBytes: 1 << 32,   // 4 GiB
        maxTotalWorkBytes: 64 << 30,   // 64 GiB
        maxParallelism: 256
    )
    /// Differs from `mainApp` only in peak memory, which sits well above any
    /// real iOS AutoFill allowance on purpose: `AutoFillMemoryLimit` pre-flights
    /// the actual device budget and must stay the only check that can refuse a
    /// vault that would otherwise open. This ceiling exists for hostile
    /// headers, and for macOS where that runtime check has no API.
    static let autoFillExtension = KDFExecutionPolicy(
        maxPeakMemoryBytes: 512 << 20, // 512 MiB
        maxTotalWorkBytes: 64 << 30,   // 64 GiB
        maxParallelism: 256
    )

    /// The resource check `KDBXParser.deriveKey` runs before Argon2. Callers
    /// whose key skipped the KDF (an express-unlock key) run it on the header
    /// before anything that will derive under this policy, such as a save.
    func validate(kdfParameters: [String: Any]) throws {
        guard let uuid = kdfParameters["$UUID"] as? Data, uuid != KDBXParser.aesKDFUUID else { return }
        try validate(
            iterations: (kdfParameters["I"] as? UInt64) ?? 3,
            memoryBytes: (kdfParameters["M"] as? UInt64) ?? (64 * 1024 * 1024),
            parallelism: (kdfParameters["P"] as? UInt32) ?? 1
        )
    }

    /// Exact stored values run or are rejected, never clamped.
    func validate(iterations: UInt64, memoryBytes: UInt64, parallelism: UInt32) throws {
        let (totalWork, overflow) = memoryBytes.multipliedReportingOverflow(by: iterations)
        guard memoryBytes <= maxPeakMemoryBytes,
              !overflow, totalWork <= maxTotalWorkBytes,
              parallelism <= maxParallelism else {
            throw KDBXParser.ParseError.kdfResourceLimitExceeded(
                iterations: iterations,
                memoryBytes: memoryBytes,
                parallelism: parallelism
            )
        }
    }
}
