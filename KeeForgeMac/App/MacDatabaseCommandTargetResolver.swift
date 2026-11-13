import AppKit

/// Picks the database window a menu command acts on. Validation and dispatch
/// both ask it, at the moment they run, so a command never reaches a window
/// that was not the target when it fired.
///
/// - The key window, or the window a key sheet or child belongs to, when it is
///   a database window.
/// - An auxiliary key window (Settings, a panel) defers to the main window.
/// - The Databases window, or no database window, disables database commands.
@MainActor
struct MacDatabaseCommandTargetResolver<Target: AnyObject> {
    let keyWindow: NSWindow?
    let mainWindow: NSWindow?
    let launcherWindow: NSWindow?
    let target: (NSWindow) -> Target?

    func resolve() -> Target? {
        if let keyWindow {
            let owner = Self.topLevel(keyWindow)
            if let target = target(owner) { return target }
            if let launcherWindow, owner === launcherWindow { return nil }
        }
        guard let mainWindow else { return nil }
        return target(Self.topLevel(mainWindow))
    }

    static func topLevel(_ window: NSWindow) -> NSWindow {
        var current = window
        while let parent = current.sheetParent ?? current.parent, parent !== current {
            current = parent
        }
        return current
    }
}
