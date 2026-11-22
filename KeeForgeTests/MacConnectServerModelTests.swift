#if os(macOS)
import XCTest
@testable import KeeForge

@MainActor
final class MacConnectServerModelTests: XCTestCase {
    func testOnlyServerTypesAndSwitchPreservesEachFormAndWarningOptIn() {
        let model = MacConnectServerModel(prefill: false)
        XCTAssertEqual(MacConnectServerModel.serverTypes, [.webDAV, .ftp])
        model.webDAV.serverURL = "https://vault.test/"
        model.webDAV.password = "web secret"
        model.serverType = .ftp
        model.ftp.password = "ftp secret"
        XCTAssertFalse(model.showsFTPWarnings)
        model.ftp.allowsUnencryptedFTP = true
        XCTAssertTrue(model.showsFTPWarnings)
        model.serverType = .webDAV
        XCTAssertEqual(model.webDAV.serverURL, "https://vault.test/")
        XCTAssertEqual(model.webDAV.password, "web secret")
        model.clearSecrets()
        XCTAssertEqual(model.webDAV.password, "")
        XCTAssertEqual(model.ftp.password, "")
    }

    func testNextcloudChoiceIsTheWebDAVFormInNextcloudMode() {
        let model = MacConnectServerModel(prefill: false)
        XCTAssertEqual(model.serverChoice, .webDAV)
        model.serverChoice = .nextcloud
        XCTAssertEqual(model.serverType, .webDAV)
        XCTAssertTrue(model.webDAV.isNextcloud)
        model.serverChoice = .ftp
        XCTAssertEqual(model.serverType, .ftp)
        XCTAssertEqual(model.serverChoice, .ftp)
        model.serverChoice = .webDAV
        XCTAssertFalse(model.webDAV.isNextcloud)
        XCTAssertEqual(model.serverChoice, .webDAV)
    }

    func testDefaultFormsConnectThroughTheRegistryProviders() {
        XCTAssertTrue((MacConnectServerModel.webDAVConnector as AnyObject)
            === (CloudProviderRegistry.provider(for: CloudProviderKind.webDAV.rawValue) as AnyObject))
        XCTAssertTrue((MacConnectServerModel.ftpConnector as AnyObject)
            === (CloudProviderRegistry.provider(for: CloudProviderKind.ftp.rawValue) as AnyObject))
    }

    func testConnectionYieldsAccountAndEndDropsLateSuccessAndFailure() async {
        for end in [false, true] {
            for fails in [false, true] {
                let connector = P8ConnectGate()
                let form = WebDAVConnectViewModel(connector: connector)
                form.serverURL = "https://vault.test/"
                form.username = "alex"
                form.password = "secret"
                let model = MacConnectServerModel(webDAV: form, prefill: false)
                let task = Task { await model.connect() }
                await connector.started()
                XCTAssertTrue(model.isConnecting)
                if end { model.clearSecrets() }
                await connector.finish(fails: fails)
                let account = await task.value
                XCTAssertEqual(account?.id, !end && !fails ? "account" : nil)
                XCTAssertFalse(model.isConnecting)
                if end || !fails { XCTAssertEqual(form.password, "") }
                if end { XCTAssertNil(form.errorMessage) }
                model.clearSecrets()
            }
        }
    }

    func testRecentlyConnectedAccountWinsOverAlphabeticalAndInsertionOrder() async throws {
        let provider = CloudProviderKind.webDAV.rawValue
        let first = CloudAccount(id: "account", displayName: "A", provider: provider)
        let later = CloudAccount(id: "p8-later", displayName: "Z", provider: provider)
        var credentials: [String: Data] = [:]
        for account in [first, later] {
            CloudAccountStore.upsert(account)
            let credential = WebDAVCredential(serverURL: "https://" + account.displayName.lowercased() + ".test/", username: account.displayName, password: "stored")
            credentials[account.id] = try JSONEncoder().encode(credential)
        }
        defer {
            for account in [first, later] {
                CloudAccountStore.remove(provider: provider, accountId: account.id)
            }
        }
        let connector = P8ConnectGate()
        let form = WebDAVConnectViewModel(connector: connector)
        form.serverURL = "https://a.test/"; form.username = "A"; form.password = "new"
        let model = MacConnectServerModel(webDAV: form, prefill: false)
        let connection = Task { await model.connect() }
        await connector.started()
        await connector.finish(fails: false)
        _ = await connection.value
        let storedCredentials = credentials
        let next = MacConnectServerModel(credentialData: { requestedProvider, id in
            requestedProvider == provider ? storedCredentials[id] : nil
        })
        XCTAssertEqual(next.webDAV.serverURL, "https://a.test/")
        XCTAssertEqual(next.webDAV.username, "A")
        XCTAssertEqual(next.webDAV.password, "")
        next.clearSecrets(); model.clearSecrets()
    }

    func testPrefillsLatestServerAndUsernameWithoutPassword() throws {
        let id = "p8-prefill-\(UUID())"
        let account = CloudAccount(id: id, displayName: "Test", provider: CloudProviderKind.webDAV.rawValue)
        let credential = WebDAVCredential(serverURL: "http://vault.test/", username: "alex", password: "stored secret")
        CloudAccountStore.upsert(account)
        let storedCredential = try JSONEncoder().encode(credential)
        defer {
            CloudAccountStore.remove(provider: account.provider, accountId: id)
        }
        let model = MacConnectServerModel(credentialData: { provider, accountID in
            provider == account.provider && accountID == id ? storedCredential : nil
        })
        XCTAssertEqual(model.webDAV.serverURL, "http://vault.test/")
        XCTAssertEqual(model.webDAV.username, "alex")
        XCTAssertTrue(model.webDAV.allowsUnencryptedHTTP)
        XCTAssertEqual(model.webDAV.password, "")
        model.clearSecrets()
    }
}

actor P8ConnectGate: WebDAVConnecting {
    private var answer: CheckedContinuation<CloudAccount, Error>?
    private var start: CheckedContinuation<Void, Never>?
    func connect(_ configuration: WebDAVConnectionConfiguration) async throws -> CloudAccount {
        try await withCheckedThrowingContinuation {
            answer = $0
            start?.resume(); start = nil
        }
    }
    func started() async {
        if answer != nil { return }
        await withCheckedContinuation { start = $0 }
    }
    func finish(fails: Bool) {
        if fails { answer?.resume(throwing: CloudProviderError.notAuthenticated) }
        else { answer?.resume(returning: CloudAccount(id: "account", displayName: "Test", provider: CloudProviderKind.webDAV.rawValue)) }
        answer = nil
    }
}
#endif
