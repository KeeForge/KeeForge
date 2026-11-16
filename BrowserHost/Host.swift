import AppKit
import Darwin

@main
enum Host {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let prefix = Bundle.main.object(forInfoDictionaryKey: "BrowserBridgeTeamPrefix") as? String
        let container = prefix.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0 + BrowserBridgeIdentifiers.groupSuffix)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        BrowserHostRelay(socketPath: container?.appendingPathComponent(BrowserBridgeIdentifiers.socketName).path) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }.run()
    }
}
