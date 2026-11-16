import AppKit
import Darwin

@main
enum Host {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        BrowserHostRelay(socketPath: BrowserBridgeIdentifiers.socketURL()?.path) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }.run()
    }
}
