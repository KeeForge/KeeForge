#if os(macOS)
import AppKit
import Carbon.HIToolbox

/// The one system-wide shortcut KeeForge registers: the menu bar quick search.
///
/// Carbon's `RegisterEventHotKey` is still the only public API that delivers a
/// key combination while another app is frontmost without the Accessibility
/// permission, and it works inside the App Sandbox. It fails, rather than
/// stealing the combination, when another app already holds it.
@MainActor
final class MacGlobalHotKey {
    var onPressed: (() -> Void)?

    nonisolated private static let signature: OSType = 0x4B46_5153 // "KFQS"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Replaces any earlier registration. Returns `false` when macOS refuses
    /// the combination, normally because another app already registered it.
    func register(_ hotKey: SettingsService.MacHotKey) -> Bool {
        unregister()
        guard installHandlerIfNeeded() else { return false }

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        hotKeyRef = reference
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() -> Bool {
        guard handlerRef == nil else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Unretained: the app keeps its one instance for its whole lifetime.
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData, Thread.isMainThread else {
                    return OSStatus(eventNotHandledErr)
                }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == MacGlobalHotKey.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let hotKey = Unmanaged<MacGlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated {
                    hotKey.onPressed?()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
        return status == noErr
    }
}

extension SettingsService.MacHotKey {
    /// A recorded key press, or `nil` when it cannot be a global shortcut: it
    /// needs ⌘, ⌥ or ⌃, because a plain or ⇧-only key would swallow ordinary
    /// typing in every other app.
    init?(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, charactersIgnoringModifiers: String?) {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .option, .control]) == false else { return nil }
        guard let label = Self.keyLabel(keyCode: keyCode, characters: charactersIgnoringModifiers) else { return nil }

        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        self.init(keyCode: UInt32(keyCode), carbonModifiers: carbon, keyLabel: label)
    }

    /// Modifier glyphs in the order macOS menus print them: ⌃⌥⇧⌘.
    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
        kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// Escape is never a shortcut key: it is what cancels recording.
    private static func keyLabel(keyCode: UInt16, characters: String?) -> String? {
        guard Int(keyCode) != kVK_Escape else { return nil }
        if let named = namedKeys[Int(keyCode)] { return named }
        guard let characters = characters?.trimmingCharacters(in: .whitespacesAndNewlines),
              characters.isEmpty == false,
              characters.unicodeScalars.allSatisfy(isPrintable)
        else { return nil }
        return characters.uppercased()
    }

    /// AppKit reports keys without a glyph (Help, Clear, the arrows) as
    /// private-use characters in U+F700–U+F8FF.
    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) == false
            && (0xF700...0xF8FF).contains(scalar.value) == false
    }
}
#endif
