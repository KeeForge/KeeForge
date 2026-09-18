import Foundation

/// Drives the manual FTP connect form. Plain FTP carries the password in the
/// clear, so connecting requires the explicit unencrypted opt-in.
///
/// The password is never logged or included in any error string.
@MainActor
@Observable
final class FTPConnectViewModel {
    var serverURL = ""
    var username = ""
    var password = ""
    var allowsUnencryptedFTP = false
    private(set) var isConnecting = false
    var errorMessage: String?

    private let connector: any FTPConnecting

    init(connector: any FTPConnecting) {
        self.connector = connector
    }

    /// Returns the connected account, or nil with `errorMessage` set. The
    /// provider is never called when client-side validation fails.
    func connect() async -> CloudAccount? {
        guard isConnecting == false else { return nil }

        errorMessage = nil

        let trimmedServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedServerURL.isEmpty == false else {
            errorMessage = String(localized: "Enter the FTP server address.")
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

        let configuration = FTPConnectionConfiguration(
            serverURL: trimmedServerURL,
            username: trimmedUsername,
            password: password,
            allowsUnencryptedFTP: allowsUnencryptedFTP
        )

        do {
            _ = try FTPURL.normalizedBaseURL(
                from: configuration.serverURL,
                allowsUnencryptedFTP: configuration.allowsUnencryptedFTP
            )
        } catch {
            errorMessage = Self.connectionMessage(for: error)
            return nil
        }

        isConnecting = true
        defer { isConnecting = false }

        do {
            return try await connector.connect(configuration)
        } catch {
            errorMessage = Self.connectionMessage(for: error)
            return nil
        }
    }

    private static func connectionMessage(for error: Error) -> String {
        switch error {
        case FTPURLError.unsupportedScheme:
            return String(localized: "The server address must start with ftp://.")
        case FTPURLError.unencryptedNotAllowed:
            return String(localized: "FTP is not encrypted. Turn on Allow Unencrypted FTP to connect.")
        case is FTPURLError:
            return String(localized: "The server address is not a valid URL.")
        case CloudProviderError.notAuthenticated:
            return String(localized: "The FTP username or password was rejected.")
        case CloudProviderError.fileNotFound:
            return String(localized: "The FTP server has no folder at this path.")
        default:
            return error.localizedDescription
        }
    }
}
