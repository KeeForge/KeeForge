import Foundation
import Observation

@MainActor @Observable
final class AttachmentLoadCoordinator {
    private(set) var isActive = false
    private var requestID: UUID?
    private(set) var isLoading = false

    func activate() {
        isActive = true
    }

    func deactivate() {
        isActive = false
        invalidate()
    }

    func invalidate() {
        requestID = nil
        isLoading = false
    }

    @discardableResult
    func load<Value: Sendable>(
        operation: @escaping @MainActor () async -> Value,
        isCurrent: @escaping @MainActor () -> Bool,
        onCompletion: @escaping @MainActor (Value) -> Void
    ) -> Task<Void, Never>? {
        guard isActive, isLoading == false else { return nil }
        let request = UUID()
        requestID = request
        isLoading = true
        return Task { @MainActor in
            defer {
                if requestID == request {
                    requestID = nil
                    isLoading = false
                }
            }

            let value = await operation()
            guard isActive, requestID == request, isCurrent() else { return }
            onCompletion(value)
        }
    }
}
