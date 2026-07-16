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

    static func authenticate(reason: String) async throws -> LAContext {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Password"
        await MainActor.run { isBiometricAuthInProgress = true }
        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
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
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Authenticate with `.deviceOwnerAuthentication`, which allows biometrics
    /// when available and falls back to the passcode / login password / Apple
    /// Watch otherwise.
    static func authenticateDeviceOwner(reason: String) async throws -> LAContext {
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
