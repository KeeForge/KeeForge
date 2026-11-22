import Foundation
import RemoteFileTransports

/// Drives the manual WebDAV connect form. Captures the server URL, username,
/// and password, performs lightweight client-side validation, and hands a
/// validated `WebDAVConnectionConfiguration` to a `WebDAVConnecting` provider.
///
/// The password is never logged or included in any error string; only the
/// thrown error's `localizedDescription` is surfaced to the UI.
@MainActor
@Observable
final class WebDAVConnectViewModel {
    var serverURL = ""
    var username = ""
    var password = ""
    var allowsUnencryptedHTTP = false
    /// The server field takes a plain Nextcloud address; `connect()` adds the user's WebDAV path.
    var isNextcloud: Bool
    private(set) var isConnecting = false
    var errorMessage: String?

    private let connector: any WebDAVConnecting
    /// Reconnecting a database: only its own account may be connected.
    private let expectedAccountID: String?
    private var isCancelled = false

    init(connector: any WebDAVConnecting, expectedAccountID: String? = nil, isNextcloud: Bool = false) {
        self.connector = connector
        self.expectedAccountID = expectedAccountID
        self.isNextcloud = isNextcloud
    }

    /// Attempts to connect using the current field values. Returns the created
    /// `CloudAccount` on success, or `nil` on validation/connection failure
    /// (with `errorMessage` set). The provider is never called when client-side
    /// validation fails.
    func connect() async -> CloudAccount? {
        guard isConnecting == false, isCancelled == false else { return nil }

        errorMessage = nil

        let enteredServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard enteredServerURL.isEmpty == false else {
            errorMessage = isNextcloud
                ? String(localized: "Enter your Nextcloud server address.")
                : String(localized: "Enter the WebDAV server address.")
            return nil
        }

        guard trimmedUsername.isEmpty == false else {
            errorMessage = String(localized: "Enter your username.")
            return nil
        }

        guard password.isEmpty == false else {
            errorMessage = String(localized: "Enter your password.")
            return nil
        }

        let webDAVServerURL = isNextcloud
            ? NextcloudAddress.webDAVURL(server: enteredServerURL, username: trimmedUsername)
            : enteredServerURL
        let lowercasedServerURL = webDAVServerURL.lowercased()
        let usesHTTPS = lowercasedServerURL.hasPrefix("https://")
        let usesHTTP = lowercasedServerURL.hasPrefix("http://")

        guard usesHTTPS || (usesHTTP && allowsUnencryptedHTTP) else {
            if usesHTTP {
                errorMessage = String(localized: "Turn on Allow Unencrypted HTTP in Advanced to use an http:// server address.")
            } else {
                errorMessage = String(localized: "The server address must start with https://.")
            }
            return nil
        }

        if let expectedAccountID,
           let baseURL = try? WebDAVURL.normalizedBaseURL(from: webDAVServerURL,
                                                          allowsUnencryptedHTTP: allowsUnencryptedHTTP),
           WebDAVURL.accountId(normalizedBaseURL: baseURL, username: trimmedUsername) != expectedAccountID {
            errorMessage = String(localized: "This database was added with a different server address or username.")
            return nil
        }

        isConnecting = true
        defer { isConnecting = false }

        let configuration = WebDAVConnectionConfiguration(
            serverURL: webDAVServerURL,
            username: trimmedUsername,
            password: password,
            allowsUnencryptedHTTP: allowsUnencryptedHTTP
        )

        do {
            let account = try await connector.connect(configuration)
            guard isCancelled == false, Task.isCancelled == false else { return nil }
            password = ""
            return account
        } catch {
            guard isCancelled == false, Task.isCancelled == false else { return nil }
            errorMessage = Self.connectionMessage(for: error)
            return nil
        }
    }

    func cancelPendingConnection() {
        isCancelled = true
        password = ""
    }

    private static func connectionMessage(for error: Error) -> String {
        if let cloudError = error as? CloudProviderError, cloudError == .notAuthenticated {
            return String(localized: "The WebDAV username or password was rejected.")
        }

        return error.localizedDescription
    }
}

/// Builds a Nextcloud user's WebDAV files address from the server address people know.
enum NextcloudAddress {
    /// `cloud.example.com` and `alex` give `https://cloud.example.com/remote.php/dav/files/alex/`.
    /// A full WebDAV address is kept as entered, and an explicit scheme is never changed, so
    /// the form's HTTPS rules still apply.
    static func webDAVURL(server: String, username: String) -> String {
        var address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.contains("://") == false {
            address = "https://" + address
        }
        if address.range(of: "/remote.php/", options: .caseInsensitive) != nil {
            return address
        }
        // A browser address such as `…/index.php/apps/files/` or `…/apps/files/` names the same server.
        for marker in ["?", "#", "/index.php", "/apps/"] {
            if let range = address.range(of: marker, options: .caseInsensitive) {
                address = String(address[..<range.lowerBound])
            }
        }
        while address.hasSuffix("/") {
            address.removeLast()
        }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedUser = user.addingPercentEncoding(withAllowedCharacters: userPathAllowed) ?? user
        return address + "/remote.php/dav/files/" + encodedUser + "/"
    }

    private static let userPathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
}
