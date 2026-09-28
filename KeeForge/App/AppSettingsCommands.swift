#if os(iOS)
import SwiftUI

// App-level Settings entry points for the iOS build. They matter when the iPad
// app runs on a Mac ("Designed for iPad"): the sidebar gear is hidden there and
// the system "Settings…" menu item opens a compatibility window instead of
// `SettingsView`. `KeeForgeApp` owns the presenter so any column can raise it.

@MainActor
@Observable
final class AppSettingsPresentation {
    var isPresented = false
}

/// Replaces the app menu's Settings… item (⌘,) with one that presents the
/// app-owned `SettingsView` sheet.
struct AppSettingsCommands: Commands {
    let presentation: AppSettingsPresentation

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                presentation.isPresented = true
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

extension View {
    /// Adds a Settings gear to this view's navigation bar, only when the iPad
    /// app is running on a Mac; a no-op on iPhone and iPad.
    func appSettingsToolbarButton() -> some View {
        modifier(AppSettingsToolbarModifier())
    }
}

private struct AppSettingsToolbarModifier: ViewModifier {
    @Environment(AppSettingsPresentation.self) private var presentation

    func body(content: Content) -> some View {
        content.toolbar {
            if ProcessInfo.processInfo.isiOSAppOnMac {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentation.isPresented = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("app.settings.button")
                }
            }
        }
    }
}
#endif
