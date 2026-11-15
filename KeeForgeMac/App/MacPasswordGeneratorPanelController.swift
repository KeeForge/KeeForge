import AppKit
import Observation
import SwiftUI

/// The app's one Password Generator panel (Generator board): a utility panel that floats over the
/// database windows, on a `PasswordGeneratorModel` whose options are the editor popover's
/// remembered set. It opens only while a database is unlocked and closes when none is. Closing
/// drops the model and its suggestion; Copy goes through `ClipboardService` (concealed, timed,
/// cleared on lock).
@MainActor @Observable
final class MacPasswordGeneratorPanelController {
    /// The open panel's model; nil once it closes.
    private(set) var model: PasswordGeneratorModel?
    @ObservationIgnored private(set) var panel: MacPasswordGeneratorPanel?

    @ObservationIgnored private let hasUnlockedSession: @MainActor () -> Bool
    @ObservationIgnored private let blockCapture: @MainActor () -> Bool
    @ObservationIgnored private let present: @MainActor (NSPanel) -> Void
    @ObservationIgnored private let makeModel: @MainActor () -> PasswordGeneratorModel
    @ObservationIgnored private let observation = MacObservation()

    /// `hasUnlockedSession` must read observable state. Tests pass a `present` that never orders the panel front.
    init(
        hasUnlockedSession: @escaping @MainActor () -> Bool,
        blockCapture: @escaping @MainActor () -> Bool = { SettingsService.blockScreenCapture },
        present: @escaping @MainActor (NSPanel) -> Void = { $0.makeKeyAndOrderFront(nil) },
        makeModel: @escaping @MainActor () -> PasswordGeneratorModel = { PasswordGeneratorModel() }
    ) {
        self.hasUnlockedSession = hasUnlockedSession
        self.blockCapture = blockCapture
        self.present = present
        self.makeModel = makeModel
    }

    /// Opens the panel, or brings the open one front.
    func show() {
        guard hasUnlockedSession() else { return }
        if let panel {
            present(panel)
            return
        }
        let model = makeModel()
        let panel = makePanel(model: model)
        self.model = model
        self.panel = panel
        observation.start(reading: { [hasUnlockedSession] in hasUnlockedSession() }, onChange: { [weak self] isUnlocked in
            if isUnlocked == false { self?.close() }
        })
        present(panel)
    }

    func close() {
        observation.cancel()
        if let panel {
            panel.onClose = nil
            panel.orderOut(nil)
            panel.contentView = nil
        }
        model?.close()
        model = nil
        panel = nil
    }

    private func makePanel(model: PasswordGeneratorModel) -> MacPasswordGeneratorPanel {
        let hosting = NSHostingView(rootView: MacPasswordGeneratorPanelView(model: model).modifier(MacHostingAppearance()))
        let size = hosting.fittingSize
        let panel = MacPasswordGeneratorPanel(contentRect: NSRect(origin: .zero, size: size),
                                              styleMask: [.titled, .closable, .utilityWindow],
                                              backing: .buffered, defer: true)
        // Set before it is first shown: the capture sweep runs only when a window becomes key.
        panel.sharingType = ScreenProtectionService.windowSharingType(blockCapture: blockCapture())
        panel.title = String(localized: "Password Generator")
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.setAccessibilityIdentifier("password-generator.panel")
        panel.contentView = hosting
        panel.center()
        panel.onClose = { [weak self] in self?.close() }
        return panel
    }
}

/// Only a close button; Escape closes it too.
final class MacPasswordGeneratorPanel: NSPanel {
    var onClose: (@MainActor () -> Void)?

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func close() {
        super.close()
        let onClose = onClose
        self.onClose = nil
        withExtendedLifetime(self) { onClose?() }
    }
}
