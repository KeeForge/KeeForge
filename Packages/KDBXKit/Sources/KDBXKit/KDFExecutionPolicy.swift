import Foundation

/// Budget for executing an attacker-controlled KDF configuration.
/// Format validity is checked separately; this bounds local resource use only.
public struct KDFExecutionPolicy: Sendable, Equatable {
    /// Upper bound on the Argon2 memory parameter (peak allocation).
    public let maxPeakMemoryBytes: UInt64
    /// Upper bound on memory × iterations (total bytes processed), the real CPU cost proxy.
    public let maxTotalWorkBytes: UInt64
    /// Upper bound on Argon2 lanes/threads.
    public let maxParallelism: UInt32

    public init(maxPeakMemoryBytes: UInt64, maxTotalWorkBytes: UInt64, maxParallelism: UInt32) {
        self.maxPeakMemoryBytes = maxPeakMemoryBytes
        self.maxTotalWorkBytes = maxTotalWorkBytes
        self.maxParallelism = maxParallelism
    }

    /// The resource check `KDBXContainer.deriveKey` runs before Argon2. Callers
    /// whose key skipped the KDF (an express-unlock key) run it on the header
    /// before anything that will derive under this policy, such as a save.
    public func validate(kdfParameters: [String: Any]) throws {
        guard let uuid = kdfParameters["$UUID"] as? Data, uuid != KDBXContainer.aesKDFUUID else { return }
        try validate(
            iterations: (kdfParameters["I"] as? UInt64) ?? 3,
            memoryBytes: (kdfParameters["M"] as? UInt64) ?? (64 * 1024 * 1024),
            parallelism: (kdfParameters["P"] as? UInt32) ?? 1
        )
    }

    /// Exact stored values run or are rejected, never clamped.
    public func validate(iterations: UInt64, memoryBytes: UInt64, parallelism: UInt32) throws {
        let (totalWork, overflow) = memoryBytes.multipliedReportingOverflow(by: iterations)
        guard memoryBytes <= maxPeakMemoryBytes,
              !overflow, totalWork <= maxTotalWorkBytes,
              parallelism <= maxParallelism else {
            throw KDBXContainer.ParseError.kdfResourceLimitExceeded(
                iterations: iterations,
                memoryBytes: memoryBytes,
                parallelism: parallelism
            )
        }
    }
}
