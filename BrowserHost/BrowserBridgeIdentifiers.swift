#if os(macOS)
enum BrowserBridgeIdentifiers {
    static let groupSuffix = "com.keevault.browser"
    static let socketName = "b.sock"
    static let nativeHostName = "com.keevault.browser"
    static let firefoxExtensionID = "browser-extension@keeforge.com"
    // The store-assigned ID goes here once the extension is listed. Debug builds also
    // allow the unpacked extension, whose ID comes from the `key` in its manifest.
    static let chromiumExtensionOrigins: [String] = {
        var origins: [String] = []
        #if DEBUG
        origins.append("chrome-extension://pihelgeaeflnpjjdajbdmfmcpgeoefbf/")
        #endif
        return origins
    }()
}
#endif
