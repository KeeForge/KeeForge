@preconcurrency import AuthenticationServices
import OSLog

enum CredentialIdentityStoreManager: Sendable {
    private static let logger = Logger(subsystem: "KeeForge", category: "CredentialIdentityStore")

    #if DEBUG
    @MainActor static var populateObserver: (([KPEntry]) -> Void)?
    @MainActor static var clearObserver: (() -> Void)?
    #endif

    static func populate(with entries: [KPEntry]) {
        let eligibleEntries = entries.filter { !$0.isExpired() }

        #if DEBUG
        Task { @MainActor in
            populateObserver?(eligibleEntries)
        }
        #endif

        Task {
            let store = ASCredentialIdentityStore.shared
            let state = await store.state()
            guard state.isEnabled else {
                logger.info("Identity store is not enabled; skipping populate")
                return
            }

            let passwordIds = eligibleEntries.flatMap(passwordIdentities(for:))
            let passkeyIds = eligibleEntries.compactMap(passkeyIdentity(for:))

            var allIdentities: [any ASCredentialIdentity] = passwordIds
            allIdentities.append(contentsOf: passkeyIds)

            var otcCount = 0
            if #available(iOS 18.0, macOS 15.0, *) {
                let otcIds = eligibleEntries.compactMap(oneTimeCodeIdentity(for:))
                allIdentities.append(contentsOf: otcIds)
                otcCount = otcIds.count
            }

            do {
                if allIdentities.isEmpty {
                    try await store.removeAllCredentialIdentities()
                    logger.info("Cleared identity store because no eligible credentials remain")
                } else {
                    try await store.replaceCredentialIdentities(allIdentities)
                    logger.info("Populated identity store with \(passwordIds.count) password + \(passkeyIds.count) passkey + \(otcCount) OTC identities")
                }
            } catch {
                logger.error("Failed to replace credential identities: \(error.localizedDescription)")
            }
        }
    }

    static func clearStore() {
        #if DEBUG
        Task { @MainActor in
            clearObserver?()
        }
        #endif

        Task {
            let store = ASCredentialIdentityStore.shared
            let state = await store.state()
            guard state.isEnabled else { return }

            do {
                try await store.removeAllCredentialIdentities()
                logger.info("Cleared all credential identities")
            } catch {
                logger.error("Failed to clear credential identities: \(error.localizedDescription)")
            }
        }
    }

    static func removeIdentities(for entries: [KPEntry]) {
        Task {
            let store = ASCredentialIdentityStore.shared
            let state = await store.state()
            guard state.isEnabled else { return }

            let passwordIds = entries.flatMap(passwordIdentities(for:))
            let passkeyIds = entries.compactMap(passkeyIdentity(for:))
            guard !passwordIds.isEmpty || !passkeyIds.isEmpty else { return }

            do {
                if !passwordIds.isEmpty {
                    try await store.removeCredentialIdentities(passwordIds)
                }
                if !passkeyIds.isEmpty {
                    try await store.removeCredentialIdentities(passkeyIds)
                }
            } catch {
                logger.error("Failed to remove credential identities: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - One-time code identities

    @available(iOS 18.0, macOS 15.0, *)
    static func oneTimeCodeIdentity(for entry: KPEntry) -> ASOneTimeCodeCredentialIdentity? {
        guard entry.hasTOTP else { return nil }

        let allURLs = [entry.url] + entry.additionalURLs
        let domain = allURLs.compactMap(domainFromURLString).first
        guard let domain else { return nil }

        let label = entry.title.isEmpty ? entry.username : entry.title
        guard !label.isEmpty else { return nil }

        let serviceIdentifier = ASCredentialServiceIdentifier(identifier: domain, type: .domain)
        return ASOneTimeCodeCredentialIdentity(
            serviceIdentifier: serviceIdentifier,
            label: label,
            recordIdentifier: entry.id.uuidString
        )
    }

    // MARK: - Passkey identities

    static func passkeyIdentity(for entry: KPEntry) -> ASPasskeyCredentialIdentity? {
        guard let passkey = entry.passkeyCredential,
              let credentialIDData = passkey.credentialIDData,
              let userHandleData = passkey.userHandleData
        else { return nil }

        let rpID = passkey.relyingParty.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !rpID.isEmpty else { return nil }

        return ASPasskeyCredentialIdentity(
            relyingPartyIdentifier: rpID,
            userName: passkey.username,
            credentialID: credentialIDData,
            userHandle: userHandleData,
            recordIdentifier: entry.id.uuidString
        )
    }

    static func normalizedRelyingPartyIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let host = CredentialMatcher.hostFromURLString(trimmed) ?? trimmed
        let lowered = host.lowercased()

        if lowered.hasPrefix("www.") {
            return String(lowered.dropFirst(4))
        }

        return lowered
    }

    // MARK: - Internal (visible to tests via @testable import)

    static func passwordIdentities(for entry: KPEntry) -> [ASPasswordCredentialIdentity] {
        let username = entry.username.isEmpty ? entry.title : entry.username
        guard !username.isEmpty else { return [] }
        guard entry.hasPassword else { return [] }

        let allURLs = [entry.url] + entry.additionalURLs
        let domains = Set(allURLs.compactMap(domainFromURLString))
        guard !domains.isEmpty else { return [] }

        return domains.sorted().map { domain in
            let serviceIdentifier = ASCredentialServiceIdentifier(identifier: domain, type: .domain)
            return ASPasswordCredentialIdentity(
                serviceIdentifier: serviceIdentifier,
                user: username,
                recordIdentifier: entry.id.uuidString
            )
        }
    }

    static func domainFromURLString(_ urlString: String) -> String? {
        guard !urlString.isEmpty else { return nil }

        let host: String?
        if let h = URL(string: urlString)?.host {
            host = h
        } else {
            host = URL(string: "https://\(urlString)")?.host
        }

        guard let host else { return nil }
        return registeredDomain(from: host)
    }

    // MARK: - Registered domain extraction

    /// Extracts the registered domain (eTLD+1) from a host string.
    /// Strips `www.` prefix and collapses subdomains to the base domain.
    /// Returns nil for IP addresses, localhost, and single-label hosts.
    static func registeredDomain(from host: String) -> String? {
        let lowered = host.lowercased()

        // Skip IPv6
        if lowered.contains(":") { return nil }

        let labels = lowered.split(separator: ".").map(String.init)

        // Skip single-label hosts (localhost, etc.)
        guard labels.count >= 2 else { return nil }

        // Skip IP addresses (all labels are numeric)
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return nil }

        // Strip www prefix
        var effective = labels
        if effective.first == "www" {
            effective.removeFirst()
        }
        guard effective.count >= 2 else { return nil }

        // Check for known multi-part TLDs (co.uk, com.au, etc.)
        let lastTwo = effective.suffix(2).joined(separator: ".")
        if Self.knownMultiPartTLDs.contains(lastTwo) {
            guard effective.count >= 3 else { return nil }
            return effective.suffix(3).joined(separator: ".")
        }

        return effective.suffix(2).joined(separator: ".")
    }

    private static let knownMultiPartTLDs: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk",
        "com.au", "org.au", "net.au", "edu.au",
        "co.nz", "org.nz", "net.nz",
        "co.jp", "or.jp", "ne.jp", "ac.jp",
        "com.br", "org.br", "net.br",
        "co.in", "org.in", "net.in",
        "co.za", "org.za", "net.za",
        "com.mx", "org.mx",
        "co.kr", "or.kr",
        "com.cn", "org.cn", "net.cn",
        "com.tw", "org.tw", "net.tw",
        "co.il", "org.il",
        "com.sg", "org.sg",
        "com.hk", "org.hk",
        "co.th", "or.th",
        "com.tr", "org.tr",
        "com.ar", "org.ar",
        "co.id",
        "com.ph",
        "com.my",
        "com.ng",
        "co.ke",
    ]
}
