import Observation

/// Observation calls back before mutation; the next main-actor turn reads the settled state.
@MainActor
final class MacObservation {
    private var generation = 0
    private var refresh: (() -> Void)?

    func start<Value>(
        reading read: @escaping @MainActor () -> Value,
        onChange: @escaping @MainActor (Value) -> Void
    ) {
        cancel()
        let generation = generation
        refresh = { [weak self] in
            guard let self, self.generation == generation else { return }
            let value = withObservationTracking {
                read()
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.refresh?()
                }
            }
            onChange(value)
        }
        refresh?()
    }

    func cancel() {
        generation += 1
        refresh = nil
    }
}
