import SwiftUI

#if os(macOS)
@MainActor
final class MacSheetCancellationScope {
    private var actions: [UUID: @MainActor () -> Void] = [:]
    private var hasEnded = false

    @discardableResult
    func register(_ cancel: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        if hasEnded { cancel() } else { actions[id] = cancel }
        return id
    }

    func unregister(_ id: UUID) { actions[id] = nil }

    func cancel() {
        guard !hasEnded else { return }
        hasEnded = true
        let pending = actions.values
        actions = [:]
        for action in pending { action() }
    }
}

extension EnvironmentValues {
    @Entry var macSheetCancellationScope: MacSheetCancellationScope? = nil
}

private struct MacSheetCancellationModifier: ViewModifier {
    @Environment(\.macSheetCancellationScope) private var scope
    @State private var registration: UUID?
    let onEnd: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.onAppear {
            if registration == nil { registration = scope?.register(onEnd) }
        }.onDisappear {
            if let registration { scope?.unregister(registration) }
            registration = nil
        }
    }
}
#endif

extension View {
    @ViewBuilder
    func macSheetCancellation(onEnd: @escaping @MainActor () -> Void) -> some View {
        #if os(macOS)
        modifier(MacSheetCancellationModifier(onEnd: onEnd))
        #else
        self
        #endif
    }
}
