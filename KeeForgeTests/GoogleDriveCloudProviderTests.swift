import AuthenticationServices
import XCTest
@testable import KeeForge

final class GoogleDriveCloudProviderTests: XCTestCase {
    private let bytes = Data("encrypted-payload".utf8)

    private func resource(id: String = "file_A", name: String = "vault.kdbx", bytes: Data? = nil, version: String = "12") -> [String: Any] {
        let payload = bytes ?? self.bytes
        return ["id": id, "name": name, "mimeType": "application/octet-stream", "size": String(payload.count), "modifiedTime": "2026-11-08T12:00:00.000Z", "version": version, "sha256Checksum": GoogleDriveCloudProvider.sha256(payload)]
    }

    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func testReplacementAndLegacyCreationRejectBeforeAnyHTTP() async throws {
        let transport = GoogleDriveTestTransport([])
        let provider = GoogleDriveCloudProvider(authorization: GoogleDriveTestAuthorization(), transport: transport, creationEnabled: true, isAccountConnected: { _ in true })
        XCTAssertEqual(provider.writeGuarantee(expectedRev: "12", byteCount: 1), .disabled)
        do {
            _ = try await provider.upload(accountId: "account", fileId: "file_A", data: bytes, expectedRev: "12", progress: { _ in })
            XCTFail("Replacement must be disabled")
        } catch { XCTAssertEqual(error as? CloudProviderError, .writeScopeRequired) }
        do {
            _ = try await provider.createFile(accountId: "account", path: "vault.kdbx", data: bytes, progress: { _ in })
            XCTFail("Legacy create cannot retain a durable ID")
        } catch { XCTAssertEqual(error as? CloudProviderError, .writeScopeRequired) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testDefaultCreationGateAndMissingIDNeverDispatch() async throws {
        let transport = GoogleDriveTestTransport([])
        for enabled in [false, true] {
            let provider = GoogleDriveCloudProvider(authorization: GoogleDriveTestAuthorization(), transport: transport, creationEnabled: enabled, isAccountConnected: { _ in true })
            do {
                _ = try await provider.createFile(accountId: "account", path: "vault.kdbx", data: bytes, creationID: nil, progress: { _ in })
                XCTFail("Missing durable ID must refuse")
            } catch { XCTAssertEqual(error as? CloudProviderError, enabled ? .invalidConfiguration : .writeScopeRequired) }
            XCTAssertFalse(provider.isAvailableForSynchronization)
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testListPaginatesAndPreservesDuplicateNamesAndFileIDs() async throws {
        let transport = GoogleDriveTestTransport([
            .response(200, try json(["files": [resource(id: "file_A")], "nextPageToken": "next"])),
            .response(200, try json(["files": [resource(id: "file_B"), resource(id: "file_C", name: "notes.txt")]]))
        ])
        let provider = GoogleDriveCloudProvider(authorization: GoogleDriveTestAuthorization(), transport: transport, isAccountConnected: { _ in true })
        let files = try await provider.listFiles(accountId: "account", path: nil, query: "a'b\\c", includesAllFiles: false)
        XCTAssertEqual(files.map(\.id), ["file_A", "file_B"])
        XCTAssertEqual(files.map(\.path), ["file_A", "file_B"])
        XCTAssertEqual(files.map(\.name), ["vault.kdbx", "vault.kdbx"])
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first(where: { $0.name == "q" })?.value, "trashed = false and name contains 'a\\'b\\\\c'")
        XCTAssertEqual(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!.first(where: { $0.name == "pageToken" })?.value, "next")
    }

    func testGeneratedIDAndMultipartCreationUseSameIdentity() async throws {
        let transport = GoogleDriveTestTransport([
            .response(200, try json(["ids": ["generated_A"]])),
            .response(200, try json(resource(id: "generated_A", name: "duplicate.kdbx")))
        ])
        let provider = GoogleDriveCloudProvider(authorization: GoogleDriveTestAuthorization(), transport: transport, creationEnabled: true, isAccountConnected: { _ in true })
        let id = try await provider.prepareFileCreationID(accountId: "account")
        let created = try await provider.createFile(accountId: "account", path: "duplicate.kdbx", data: bytes, creationID: id, progress: { _ in })
        XCTAssertEqual(created.file.id, "generated_A")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/drive/v3/files/generateIds")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].url?.path, "/upload/drive/v3/files")
        let body = String(decoding: requests[1].httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("\"id\":\"generated_A\""))
        XCTAssertTrue(body.contains("duplicate.kdbx"))
        XCTAssertTrue(body.contains("encrypted-payload"))
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "If-Match"))
    }

    func testResponseLossRetryReusesCallerIDAndReconciles409WithExactBytes() async throws {
        let transport = GoogleDriveTestTransport([
            .failure(.networkConnectionLost),
            .response(409, Data()),
            .response(200, bytes),
            .response(200, try json(resource(id: "generated_A")))
        ])
        let provider = GoogleDriveCloudProvider(authorization: GoogleDriveTestAuthorization(), transport: transport, creationEnabled: true, isAccountConnected: { _ in true })
        do {
            _ = try await provider.createFile(accountId: "account", path: "vault.kdbx", data: bytes, creationID: "generated_A", progress: { _ in })
            XCTFail("Lost response must remain uncertain for caller")
        } catch {}
        let result = try await provider.createFile(accountId: "account", path: "vault.kdbx", data: bytes, creationID: "generated_A", progress: { _ in })
        XCTAssertEqual(result.file.id, "generated_A")
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "GET", "GET"])
        for request in requests.prefix(2) {
            XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains("\"id\":\"generated_A\""))
        }
        XCTAssertEqual(requests[2].url?.path, "/drive/v3/files/generated_A")
        XCTAssertFalse(requests.contains { $0.url?.path.contains("generateIds") == true })
    }

    func test409WithDifferentBytesIsConflictAndNeverMutatesAgain() async throws {
        let transport = GoogleDriveTestTransport([.response(409, Data()), .response(200, Data("other ciphertext".utf8))])
        let provider = GoogleDriveCloudProvider(authorization: GoogleDriveTestAuthorization(), transport: transport, creationEnabled: true, isAccountConnected: { _ in true })
        do {
            _ = try await provider.createFile(accountId: "account", path: "vault.kdbx", data: bytes, creationID: "generated_A", progress: { _ in })
            XCTFail("Unrelated content cannot confirm delivery")
        } catch { XCTAssertEqual(error as? CloudProviderError, .conflict(remoteRev: nil)) }
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET"])
    }

    func testDownloadOnlyReturnsMetadataThatMatchesDownloadedBytes() async throws {
        for matches in [false, true] {
            let transport = GoogleDriveTestTransport([
                .response(200, bytes),
                .response(200, try json(resource(bytes: matches ? bytes : Data("new revision".utf8))))
            ])
            let provider = GoogleDriveCloudProvider(authorization: GoogleDriveTestAuthorization(), transport: transport, isAccountConnected: { _ in true })
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            let metadata = try await provider.download(accountId: "account", fileId: "file_A", to: url, progress: { _ in })
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(metadata?.rev, matches ? "12" : nil)
            XCTAssertEqual(metadata?.size, matches ? Int64(bytes.count) : nil)
        }
    }

    func testMetadataDoesNotFabricateMissingSizeOrModificationDate() async throws {
        for omitted in ["size", "modifiedTime"] {
            var item = resource()
            item.removeValue(forKey: omitted)
            let transport = GoogleDriveTestTransport([.response(200, try json(item))])
            let provider = GoogleDriveCloudProvider(authorization: GoogleDriveTestAuthorization(), transport: transport, isAccountConnected: { _ in true })
            do {
                _ = try await provider.getMetadata(accountId: "account", fileId: "file_A")
                XCTFail("Unknown metadata must not be invented")
            } catch { XCTAssertEqual(error as? CloudProviderError, .serviceUnavailable) }
        }
    }

    @MainActor
    func testAuthenticateAndPickerRegisterAccountAndSignOutRemovesIt() async throws {
        for usePicker in [false, true] {
            let account = CloudAccount(id: "account-A", displayName: "Test Account", provider: "googledrive")
            let grant = GoogleDriveGrant(account: account, pickedFileIDs: ["file_A"])
            let accounts = GoogleDriveTestAccountStorage()
            let transport = GoogleDriveTestTransport([.response(200, try json(resource()))])
            let provider = GoogleDriveCloudProvider(
                authorization: GoogleDriveTestAuthorization(grant: grant), transport: transport,
                upsertAccount: { accounts.upsert($0) }, removeAccount: { accounts.remove($0) },
                isAccountConnected: { accounts.contains($0) }
            )
            XCTAssertFalse(provider.isAuthenticated(accountId: account.id))
            if usePicker {
                let selected = try await provider.selectFiles(from: ASPresentationAnchor(), expectedAccountID: account.id)
                XCTAssertEqual(selected.map(\.account), [account])
            } else {
                let authenticated = try await provider.authenticate(from: ASPresentationAnchor())
                XCTAssertEqual(authenticated, account)
            }
            XCTAssertTrue(accounts.contains(account.id))
            XCTAssertTrue(provider.isAuthenticated(accountId: account.id))
            provider.signOut(accountId: account.id)
            XCTAssertFalse(accounts.contains(account.id))
            XCTAssertFalse(provider.isAuthenticated(accountId: account.id))
            do {
                _ = try await provider.getMetadata(accountId: account.id, fileId: "file_A")
                XCTFail("Disconnected account must fence even retained Keychain state")
            } catch { XCTAssertEqual(error as? CloudProviderError, .notAuthenticated) }
        }
    }

    @MainActor
    func testAccountMismatchDoesNotRegisterSelectedAccount() async throws {
        let account = CloudAccount(id: "other-account", displayName: "Other", provider: "googledrive")
        let accounts = GoogleDriveTestAccountStorage()
        let provider = GoogleDriveCloudProvider(
            authorization: GoogleDriveTestAuthorization(grant: GoogleDriveGrant(account: account, pickedFileIDs: ["file_A"])),
            transport: GoogleDriveTestTransport([]), upsertAccount: { accounts.upsert($0) },
            removeAccount: { accounts.remove($0) }, isAccountConnected: { accounts.contains($0) }
        )
        do {
            _ = try await provider.selectFiles(from: ASPresentationAnchor(), expectedAccountID: "known-account")
            XCTFail("Account identity must not rebind")
        } catch { XCTAssertEqual(error as? CloudProviderError, .permissionDenied) }
        XCTAssertFalse(accounts.contains(account.id))
    }

    func testErrorReasonsMapWithoutUsingServerMessage() throws {
        let cases: [(Int, String, CloudProviderError)] = [
            (401, "", .notAuthenticated), (403, "authError", .notAuthenticated),
            (403, "storageQuotaExceeded", .insufficientSpace), (403, "userRateLimitExceeded", .rateLimited),
            (429, "", .rateLimited), (403, "insufficientFilePermissions", .permissionDenied),
            (404, "notFound", .fileNotFound), (503, "", .serviceUnavailable)
        ]
        for (status, reason, expected) in cases {
            let body = try json(["error": ["message": "secret server text", "errors": [["reason": reason]]]])
            XCTAssertEqual(GoogleDriveResponse.error(data: body, status: status), expected)
        }
    }
}

private final class GoogleDriveTestAuthorization: GoogleDriveAuthorizing {
    let grant: GoogleDriveGrant?
    init(grant: GoogleDriveGrant? = nil) { self.grant = grant }
    @MainActor var isConfigured: Bool { true }
    @MainActor func authorize(from anchor: ASPresentationAnchor, expectedAccountID: String?) async throws -> GoogleDriveGrant {
        guard let grant else { throw CloudProviderError.authenticationCancelled }
        try GoogleDriveAuthorization.checkAccount(grant.account.id, expected: expectedAccountID)
        return grant
    }
    @MainActor func accessToken(accountID: String) async throws -> String { "test-token" }
    @MainActor func cancel() {}
    func contains(accountID: String) -> Bool { true }
    func remove(accountID: String) {}
}

private actor GoogleDriveTestTransport: GoogleDriveTransport {
    enum Step: Sendable { case response(Int, Data); case failure(URLError.Code) }
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !steps.isEmpty else { throw CloudProviderError.serviceUnavailable }
        switch steps.removeFirst() {
        case .response(let status, let data):
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        case .failure(let code): throw URLError(code)
        }
    }
}

private final class GoogleDriveTestAccountStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: [String: CloudAccount] = [:]
    func upsert(_ account: CloudAccount) { lock.lock(); defer { lock.unlock() }; accounts[account.id] = account }
    func remove(_ account: String) { lock.lock(); defer { lock.unlock() }; accounts[account] = nil }
    func contains(_ account: String) -> Bool { lock.lock(); defer { lock.unlock() }; return accounts[account] != nil }
}
