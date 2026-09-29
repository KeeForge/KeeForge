import Foundation
import LocalAuthentication

enum BiometricService {
    @MainActor
    static var isBiometricAuthInProgress = false

    enum BiometricType {
        case none
        case faceID
        case touchID
    }

    static var availableType: BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .none
        }
    }

    static var isAvailable: Bool {
        availableType != .none
    }

    /// The policy the app's explicit quick-unlock action evaluates. It matches
    /// `KeychainService.quickUnlockAccessControlFlags`: on the native Mac app,
    /// Touch ID or an authorized Apple Watch; on iPhone and iPad, biometrics
    /// only. Neither accepts the device passcode or the Mac login password,
    /// which is why this is narrower than `.deviceOwnerAuthentication`.
    static var quickUnlockPolicy: LAPolicy {
        #if os(macOS)
        .deviceOwnerAuthenticationWithBiometricsOrCompanion
        #else
        .deviceOwnerAuthenticationWithBiometrics
        #endif
    }

    /// Whether `quickUnlockPolicy` can be evaluated right now.
    static var isQuickUnlockAvailable: Bool {
        #if os(macOS)
        var error: NSError?
        return LAContext().canEvaluatePolicy(quickUnlockPolicy, error: &error)
        #else
        isAvailable
        #endif
    }

    /// Whether an authorized Apple Watch can approve the Mac app's quick
    /// unlock right now. Always false on iPhone and iPad.
    static var isCompanionAvailable: Bool {
        #if os(macOS)
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithCompanion, error: &error)
        #else
        false
        #endif
    }

    /// AutoFill keeps the biometric-only default on every platform, so its
    /// own prompt never offers Apple Watch.
    static func authenticate(
        reason: String,
        policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics
    ) async throws -> LAContext {
        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "Use Password")
        await MainActor.run { isBiometricAuthInProgress = true }
        do {
            try await context.evaluatePolicy(policy, localizedReason: reason)
            await MainActor.run { isBiometricAuthInProgress = false }
            return context
        } catch {
            await MainActor.run { isBiometricAuthInProgress = false }
            throw error
        }
    }

    // MARK: - Device-Owner Authentication (biometrics OR passcode/login password)

    /// Whether the system can authenticate the device owner by any means:
    /// Face ID / Touch ID, the device passcode, the macOS login password, or
    /// Apple Watch approval.
    ///
    /// Reveal/copy gating must use this instead of `isAvailable`: on Macs
    /// without Touch ID (and iOS devices without enrolled biometrics),
    /// `.deviceOwnerAuthentication` still prompts for the login password or
    /// passcode instead of silently skipping authentication.
    static var canAuthenticateDeviceOwner: Bool {
        // Under UI testing, never route reveal/copy through the system
        // device-owner prompt: XCUITest cannot dismiss the Face ID/passcode
        // sheet, so on CI simulators that DO have a passcode enrolled the
        // reveal flow would hang. The boundary tests opt back in through the
        // stub below. Production builds (no `-ui-testing` launch argument) are
        // unaffected.
        if ProcessInfo.processInfo.arguments.contains("-ui-testing") {
            return isUITestAuthenticationPending
        }
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// UI-test stand-in for a device-owner prompt the user never answers: the
    /// gate reports as available and `authenticateDeviceOwner` never resolves,
    /// which is how the reveal/copy boundary tests observe "authentication was
    /// requested and nothing was disclosed" without a system dialog XCUITest
    /// cannot drive.
    private static var isUITestAuthenticationPending: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
            && ProcessInfo.processInfo.environment["UI_TEST_DEVICE_OWNER_AUTH_PENDING"] == "1"
    }

    /// Authenticate with `.deviceOwnerAuthentication`, which allows biometrics
    /// when available and falls back to the passcode / login password / Apple
    /// Watch otherwise.
    static func authenticateDeviceOwner(reason: String) async throws -> LAContext {
        if isUITestAuthenticationPending {
            try await Task.sleep(for: .seconds(3600))
            throw LAError(.userCancel)
        }
        let context = LAContext()
        await MainActor.run { isBiometricAuthInProgress = true }
        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            await MainActor.run { isBiometricAuthInProgress = false }
            return context
        } catch {
            await MainActor.run { isBiometricAuthInProgress = false }
            throw error
        }
    }
}
