import AppKit
import Darwin

@main
enum Host {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        BrowserHostRelay(socketPath: BrowserBridgeIdentifiers.socketURL()?.path) {
            guard let app else { return }
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }.run()
    }
}
