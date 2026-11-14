struct PickerPresentationState<T> {
    private(set) var activeTarget: T?
    private(set) var isPresented = false

    mutating func present(_ target: T) {
        activeTarget = target
        isPresented = true
    }

    mutating func updatePresentation(_ isPresented: Bool) {
        self.isPresented = isPresented
    }

    mutating func consumeActiveTarget() -> T? {
        defer {
            activeTarget = nil
            isPresented = false
        }

        return activeTarget
    }
}
