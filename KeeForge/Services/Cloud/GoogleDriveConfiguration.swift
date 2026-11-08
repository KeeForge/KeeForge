import Foundation

struct GoogleDriveConfiguration: Sendable, Equatable {
    let clientID: String
    let redirectURL: URL

    init?(clientID: String?, redirectURI: String?) {
        guard let clientID, let redirectURI,
              clientID == clientID.trimmingCharacters(in: .whitespacesAndNewlines),
              clientID.hasSuffix(".apps.googleusercontent.com"),
              clientID.count > ".apps.googleusercontent.com".count,
              !clientID.contains("$("), !clientID.contains("<"),
              let url = URL(string: redirectURI),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, !scheme.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              scheme != "http", scheme != "https",
              scheme == "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: ""),
              components.host == nil, components.path == "/oauthredirect" else { return nil }
        self.clientID = clientID
        self.redirectURL = url
    }

    static func load(bundle: Bundle = .main) -> Self? {
        #if os(macOS)
        let prefix = "GoogleDriveMac"
        #else
        let prefix = "GoogleDriveIOS"
        #endif
        return Self(
            clientID: bundle.object(forInfoDictionaryKey: prefix + "ClientID") as? String,
            redirectURI: bundle.object(forInfoDictionaryKey: prefix + "RedirectURI") as? String
        )
    }
}

enum GoogleDriveCallback {
    static let scope = "https://www.googleapis.com/auth/drive.file"

    static func pickedIDs(url: URL, redirectURL: URL, state: String) throws -> [String] {
        guard var callback = URLComponents(url: url, resolvingAgainstBaseURL: false),
              callback.fragment == nil else { throw CloudProviderError.invalidConfiguration }
        let items = callback.queryItems ?? []
        callback.query = nil
        guard callback.url?.absoluteString == redirectURL.absoluteString,
              Set(items.map(\.name)).count == items.count,
              items.first(where: { $0.name == "state" })?.value == state else {
            throw CloudProviderError.invalidConfiguration
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw error == "access_denied" ? CloudProviderError.authenticationCancelled : .notAuthenticated
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
              let rawIDs = items.first(where: { $0.name == "picked_file_ids" })?.value else {
            throw CloudProviderError.permissionDenied
        }
        if let scopes = items.first(where: { $0.name == "scope" })?.value {
            guard Set(scopes.split(separator: " ").map(String.init)) == [scope] else {
                throw CloudProviderError.permissionDenied
            }
        }
        let ids = rawIDs.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !ids.isEmpty, ids.allSatisfy(validID), Set(ids).count == ids.count else {
            throw CloudProviderError.permissionDenied
        }
        return ids
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
}
