#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Settings ▸ Menu Bar: the opt-in quick-access item and its global shortcut.
struct MacMenuBarSettingsTab: View {
    @Bindable var controller: MacQuickAccessController

    var body: some View {
        Form {
            Section {
                Toggle("Show KeeForge in the Menu Bar", isOn: $controller.isMenuBarItemEnabled)
                    .accessibilityIdentifier("settings.menu-bar.toggle")

                LabeledContent("Quick Search Shortcut") {
                    MacShortcutRecorder(
                        shortcut: $controller.shortcut,
                        isRecording: $controller.isRecordingShortcut
                    )
                }
                .disabled(controller.isMenuBarItemEnabled == false)
            } footer: {
                if controller.isShortcutUnavailable {
                    Text("Another app is already using this shortcut. Choose a different one.")
                        .foregroundStyle(.red)
                }
                Text("Search the open database from the menu bar, or press the shortcut in any app. Entries appear only while the database is unlocked, and copying a password asks for Touch ID or your login password, as it does in the main window.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: controller.isMenuBarItemEnabled) { _, isEnabled in
            if !isEnabled {
                controller.isRecordingShortcut = false
            }
        }
    }
}

/// Records one key combination for the global shortcut. Escape cancels; a
/// combination without ⌘, ⌥ or ⌃ is refused with a beep.
struct MacShortcutRecorder: View {
    @Binding var shortcut: SettingsService.MacHotKey?
    @Binding var isRecording: Bool
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Group {
                    if isRecording {
                        Text("Type Shortcut…")
                    } else if let shortcut {
                        Text(verbatim: shortcut.displayString)
                    } else {
                        Text("Record Shortcut")
                    }
                }
                .frame(minWidth: 110)
            }
            .accessibilityIdentifier("settings.menu-bar.shortcut-recorder")

            if shortcut != nil, isRecording == false {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear Shortcut")
                .accessibilityLabel("Clear Shortcut")
                .accessibilityIdentifier("settings.menu-bar.shortcut-clear")
            }
        }
        .onDisappear(perform: stopRecording)
        .onChange(of: isRecording) { _, isRecording in
            if !isRecording {
                stopRecording()
            }
        }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        // Only keys typed into Settings are recorded; typing in another window
        // after clicking away passes through untouched.
        let settingsWindowNumber = NSApp.keyWindow?.windowNumber
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.windowNumber == settingsWindowNumber else { return event }
            let keyCode = event.keyCode
            let recorded = SettingsService.MacHotKey(
                keyCode: keyCode,
                modifierFlags: event.modifierFlags,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            )
            MainActor.assumeIsolated {
                if Int(keyCode) == kVK_Escape {
                    stopRecording()
                } else if let recorded {
                    shortcut = recorded
                    stopRecording()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }
}
#endif
