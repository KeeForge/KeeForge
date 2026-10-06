import Foundation

/// The device-owner gate in front of revealing or copying a protected value,
/// for one database session. A successful unlock or device-owner
/// authentication opens a grace period, bounded by
/// `SettingsService.authenticationGracePeriod`, during which the gate asks for
/// nothing further.
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

    private struct Grant {
        let start: ContinuousClock.Instant
        let duration: Duration
    }

    /// Every live gate, held weakly, so a changed setting reaches the grants
    /// that no reveal or copy has asked about since.
    private static let liveGates = NSHashTable<SecretAccessGate>.weakObjects()

    private let gracePeriod: GracePeriodProvider
    private let now: Clock
    private let isAuthenticationAvailable: AvailabilityCheck
    private let prompt: Prompt
    private var grant: Grant?
    private var invalidationCount = 0

    init(
        gracePeriod: @escaping GracePeriodProvider = { SettingsService.authenticationGracePeriod },
        now: @escaping Clock = { .now },
        isAuthenticationAvailable: @escaping AvailabilityCheck = { BiometricService.canAuthenticateDeviceOwner },
        prompt: @escaping Prompt = { reason in
            _ = try await BiometricService.authenticateDeviceOwner(reason: reason)
        }
    ) {
        self.gracePeriod = gracePeriod
        self.now = now
        self.isAuthenticationAvailable = isAuthenticationAvailable
        self.prompt = prompt
        Self.liveGates.add(self)
    }

    /// Whoever writes the grace-period setting calls this once the new value
    /// is stored. Without it a grant that Always Ask or a shorter period
    /// should have ended would come back as soon as the old period is
    /// selected again, provided no reveal or copy fell in between.
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

    /// Shortening the setting applies at once, while lengthening it takes a
    /// new authentication, so an unlocked app in someone else's hands cannot
    /// be switched to a longer period.
    var isWithinGracePeriod: Bool {
        // Also here, for a setting written without the announcement above.
        tightenGrantToSelectedGracePeriod()
        guard let grant else { return false }
        return now() - grant.start < grant.duration
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
        grant = gracePeriod().duration.map { Grant(start: now(), duration: $0) }
    }

    func invalidate() {
        grant = nil
        invalidationCount += 1
    }

    /// Caps the grant at the period selected now and keeps the cap, so the
    /// grant cannot grow back when a longer period is selected afterwards.
    /// Always Ask revokes it.
    private func tightenGrantToSelectedGracePeriod() {
        guard let earned = grant else { return }
        guard let selected = gracePeriod().duration else {
            grant = nil
            return
        }
        grant = Grant(start: earned.start, duration: min(earned.duration, selected))
    }
}
