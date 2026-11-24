#if os(macOS)
import Foundation
import Security

enum BrowserBridgeIdentifiers {
    /// Nil when this process is not entitled to the browser group, as in an unsigned build.
    static func socketURL() -> URL? {
        groupContainerURL()?.appendingPathComponent(socketName)
    }

    /// The browser group's container, which same-user processes outside the
    /// sandbox reach without a prompt. The Mac SSH agent falls back to it too.
    static func groupContainerURL() -> URL? {
        // The group carries the signing team's prefix, so read it back from this process's own entitlements.
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
              let group = groups.first(where: { $0.hasSuffix("." + groupSuffix) }) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    static let groupSuffix = "com.keevault.browser"
    static let socketName = "b.sock"
    static let nativeHostName = "com.keevault.browser"
    static let firefoxExtensionID = "browser-extension@keeforge.com"
    static let chromeWebStoreExtensionID = "jlnelpagadpmiinbcoiiakneicmdplda"
    // Debug builds also allow the unpacked extension, whose ID comes from the `key` in its manifest.
    static let chromiumExtensionOrigins: [String] = {
        var origins = ["chrome-extension://\(chromeWebStoreExtensionID)/"]
        #if DEBUG
        origins.append("chrome-extension://pihelgeaeflnpjjdajbdmfmcpgeoefbf/")
        #endif
        return origins
    }()
}
#endif
