#if os(macOS)
import CryptoKit
import Foundation
import Security

struct PairedBrowser: Codable, Equatable, Sendable {
    let clientID: String
    let publicKey: Data
    let name: String
    let pairedAt: Date
    var lastUsedAt: Date?
}

protocol BrowserBridgeKeychain: Sendable {
    func readPrivateKey() throws -> Data?
    func createPrivateKey(_ data: Data) throws
    func deletePrivateKey() throws
}

enum BrowserPairingStoreError: Error {
    case invalidPublicKey
    case keychain(OSStatus)
    case missingApplicationIdentifier
}

/// Serializes pairing mutations and keeps key creation off the main actor.
actor BrowserPairingStore {
    private let defaults: UserDefaults
    private let keychain: any BrowserBridgeKeychain
    private let now: @Sendable () -> Date

    init(
        defaults: UserDefaults = .standard,
        keychain: any BrowserBridgeKeychain = AppBrowserBridgeKeychain(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.now = now
    }

    func list() throws -> [PairedBrowser] {
        try records().sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.clientID < $1.clientID : comparison == .orderedAscending
        }
    }

    func browser(clientID: String) throws -> PairedBrowser? {
        try records().first { $0.clientID == clientID }
    }

    func addOrReplace(_ browser: PairedBrowser) throws {
        guard browser.publicKey.count == 32 else { throw BrowserPairingStoreError.invalidPublicKey }
        var browsers = try records().filter { $0.clientID != browser.clientID }
        let sanitized = String(String.UnicodeScalarView(browser.name.unicodeScalars.filter {
            CharacterSet.controlCharacters.contains($0) == false
        }))
        let name = String(sanitized.prefix(64))
        browsers.append(PairedBrowser(
            clientID: browser.clientID, publicKey: browser.publicKey, name: name,
            pairedAt: browser.pairedAt, lastUsedAt: browser.lastUsedAt
        ))
        try persist(browsers)
    }

    func remove(clientID: String) throws {
        try persist(records().filter { $0.clientID != clientID })
    }

    func touch(clientID: String) throws {
        var browsers = try records()
        guard let index = browsers.firstIndex(where: { $0.clientID == clientID }) else { return }
        let date = now()
        if let last = browsers[index].lastUsedAt, date.timeIntervalSince(last) < 60 { return }
        browsers[index].lastUsedAt = date
        try persist(browsers)
    }

    func staticPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let data = try keychain.readPrivateKey() {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        do {
            try keychain.createPrivateKey(key.rawRepresentation)
        } catch BrowserPairingStoreError.keychain(errSecDuplicateItem) {
            // Another store may have created the installation key first.
            guard let data = try keychain.readPrivateKey() else {
                throw BrowserPairingStoreError.keychain(errSecItemNotFound)
            }
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        return key
    }

    func reset() throws {
        try keychain.deletePrivateKey()
        SettingsService.setBrowserBridgePairings(nil, in: defaults)
    }

    private func records() throws -> [PairedBrowser] {
        guard let data = SettingsService.browserBridgePairings(in: defaults) else { return [] }
        return try JSONDecoder().decode([PairedBrowser].self, from: data)
    }

    private func persist(_ browsers: [PairedBrowser]) throws {
        let data = browsers.isEmpty ? nil : try JSONEncoder().encode(browsers)
        SettingsService.setBrowserBridgePairings(data, in: defaults)
    }
}

struct AppBrowserBridgeKeychain: BrowserBridgeKeychain {
    private static let service = "com.keevault.browser-bridge"
    private static let account = "static-key"
    private static let applicationIdentifierEntitlement = "com.apple.application-identifier"

    func readPrivateKey() throws -> Data? {
        var query = try itemQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw BrowserPairingStoreError.keychain(status) }
        guard let data = result as? Data else { throw BrowserPairingStoreError.keychain(errSecDecode) }
        return data
    }

    func createPrivateKey(_ data: Data) throws {
        var query = try itemQuery()
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw BrowserPairingStoreError.keychain(status) }
    }

    func deletePrivateKey() throws {
        let status = SecItemDelete(try itemQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BrowserPairingStoreError.keychain(status)
        }
    }

    private func itemQuery() throws -> [String: Any] {
        var code: SecCode?
        var information: CFDictionary?
        let selfStatus = SecCodeCopySelf([], &code)
        guard selfStatus == errSecSuccess, let code else {
            throw BrowserPairingStoreError.keychain(selfStatus)
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw BrowserPairingStoreError.keychain(staticStatus)
        }
        let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess else { throw BrowserPairingStoreError.keychain(status) }
        let signing = information as? [String: Any]
        let entitlements = signing?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        guard let group = entitlements?[Self.applicationIdentifierEntitlement] as? String, group.isEmpty == false else {
            throw BrowserPairingStoreError.missingApplicationIdentifier
        }
        // The app identifier is accessible even when the shared group is first.
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessGroup as String: group,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
    }
}
#endif
