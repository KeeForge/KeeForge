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
}
