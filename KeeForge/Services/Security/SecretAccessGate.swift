import Foundation

/// The device-owner gate in front of revealing or copying a protected value,
/// for one database session. A successful unlock or device-owner
/// authentication opens a grace period, as long as
/// `SettingsService.authenticationGracePeriod` says (with Never Ask, until the
/// session ends it), during which the gate asks for nothing further.
///
/// The grant lives in memory only, and on a monotonic clock, so neither a
/// relaunch nor a changed system time can extend it. It never outlives the
/// shortest period selected since it was earned: a tighter setting shortens
/// or revokes it for good, and a longer one takes a new authentication.
@MainActor
final class SecretAccessGate {
    typealias GracePeriodProvider = @MainActor () -> SettingsService.AuthenticationGracePeriod
    typealias Clock = @MainActor () -> ContinuousClock.Instant
    typealias AvailabilityCheck = @MainActor () -> Bool
    typealias Prompt = @MainActor (_ reason: String) async throws -> Void
    typealias WriteCount = @MainActor () -> Int

    private struct Grant {
        let start: ContinuousClock.Instant
        /// Nil: no time limit, so only `invalidate()` ends it.
        let duration: Duration?
    }

    /// Every live gate, held weakly, so a changed setting reaches the grants
    /// that no reveal or copy has asked about since.
    private static let liveGates = NSHashTable<SecretAccessGate>.weakObjects()

    private let gracePeriod: GracePeriodProvider
    private let now: Clock
    private let isAuthenticationAvailable: AvailabilityCheck
    private let prompt: Prompt
    private let settingWriteCount: WriteCount
    /// The setting's write count when the gate last compared the grant with it.
    private var settingWritesSeen: Int
    private var grant: Grant?
    private var invalidationCount = 0

    init(
        gracePeriod: @escaping GracePeriodProvider = { SettingsService.authenticationGracePeriod },
        now: @escaping Clock = { .now },
        isAuthenticationAvailable: @escaping AvailabilityCheck = { BiometricService.canAuthenticateDeviceOwner },
        prompt: @escaping Prompt = { reason in
            _ = try await BiometricService.authenticateDeviceOwner(reason: reason)
        },
        settingWriteCount: @escaping WriteCount = { SettingsService.authenticationGracePeriodWriteCount }
    ) {
        self.gracePeriod = gracePeriod
        self.now = now
        self.isAuthenticationAvailable = isAuthenticationAvailable
        self.prompt = prompt
        self.settingWriteCount = settingWriteCount
        self.settingWritesSeen = settingWriteCount()
        Self.liveGates.add(self)
    }

    /// Whoever writes the grace-period setting calls this once the new value
    /// is stored, so each live gate caps its grant at exactly that value.
    /// A gate that missed writes revokes its grant when next asked instead.
    static func gracePeriodSettingDidChange() {
        for gate in liveGates.allObjects {
            gate.tightenGrantToSelectedGracePeriod()
        }
    }

    /// Whether a reveal or copy has to call `authenticate(reason:)` first.
    /// False inside the grace period, and when the device has no way to
    /// authenticate its owner at all.
    var requiresAuthentication: Bool {
        isWithinGracePeriod == false && isAuthenticationAvailable()
    }

    /// Whether `authenticate(reason:)` can prompt at all. A caller that must
    /// fail closed checks this instead of reading `requiresAuthentication`
    /// false as permission.
    var canAuthenticateDeviceOwner: Bool {
        isAuthenticationAvailable()
    }

    /// Shortening the setting applies at once, while lengthening it takes a
    /// new authentication, so an unlocked app in someone else's hands cannot
    /// be switched to a longer period.
    var isWithinGracePeriod: Bool {
        // Also here, for a setting written without the announcement above.
        tightenGrantToSelectedGracePeriod()
        guard let grant else { return false }
        guard let duration = grant.duration else { return true }
        return now() - grant.start < duration
    }

    /// Prompts for device-owner authentication. Success starts or refreshes
    /// the grace period; a failed or cancelled prompt ends it.
    func authenticate(reason: String) async throws {
        let invalidationCountAtPrompt = invalidationCount
        do {
            try await prompt(reason)
        } catch {
            invalidate()
            throw error
        }
        // The session locked or left the foreground while the prompt was up.
        guard invalidationCount == invalidationCountAtPrompt else { throw CancellationError() }
        noteSuccessfulAuthentication()
    }

    func noteSuccessfulAuthentication() {
        grant = Grant(start: now(), duration: gracePeriod().duration)
        settingWritesSeen = settingWriteCount()
    }

    func invalidate() {
        grant = nil
        invalidationCount += 1
    }

    /// Caps the grant at the period selected now and keeps the cap, so the
    /// grant cannot grow back when a longer period is selected afterwards.
    /// Always Ask's zero duration revokes it, and so does more than one write
    /// since the last look, because a value in between may have been Always Ask.
    private func tightenGrantToSelectedGracePeriod() {
        let writes = settingWriteCount()
        let missedAWrite = writes - settingWritesSeen > 1
        settingWritesSeen = writes
        guard let earned = grant else { return }
        if missedAWrite {
            grant = nil
            return
        }
        let selected = gracePeriod().duration
        let capped: Duration? = switch (earned.duration, selected) {
        case let (current?, limit?): min(current, limit)
        case let (current, limit): current ?? limit
        }
        grant = Grant(start: earned.start, duration: capped)
    }
}
