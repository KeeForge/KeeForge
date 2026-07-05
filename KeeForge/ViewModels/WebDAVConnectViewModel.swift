import Foundation

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
    private(set) var isConnecting = false
    var errorMessage: String?

    private let connector: any WebDAVConnecting

    init(connector: any WebDAVConnecting) {
        self.connector = connector
    }

    /// Attempts to connect using the current field values. Returns the created
    /// `CloudAccount` on success, or `nil` on validation/connection failure
    /// (with `errorMessage` set). The provider is never called when client-side
    /// validation fails.
    func connect() async -> CloudAccount? {
        guard isConnecting == false else { return nil }

        errorMessage = nil

        let trimmedServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedServerURL.isEmpty == false else {
            errorMessage = "Enter the WebDAV server address."
            return nil
        }

        guard trimmedUsername.isEmpty == false else {
            errorMessage = "Enter your username."
            return nil
        }

        guard password.isEmpty == false else {
            errorMessage = "Enter your password."
            return nil
        }

        guard trimmedServerURL.lowercased().hasPrefix("https://") else {
            errorMessage = "The server address must start with https://."
            return nil
        }

        isConnecting = true
        defer { isConnecting = false }

        let configuration = WebDAVConnectionConfiguration(
            serverURL: trimmedServerURL,
            username: trimmedUsername,
            password: password
        )

        do {
            return try await connector.connect(configuration)
        } catch {
            errorMessage = Self.connectionMessage(for: error)
            return nil
        }
    }

    private static func connectionMessage(for error: Error) -> String {
        if let cloudError = error as? CloudProviderError, cloudError == .notAuthenticated {
            return "The WebDAV username or password was rejected."
        }

        return error.localizedDescription
    }
}
