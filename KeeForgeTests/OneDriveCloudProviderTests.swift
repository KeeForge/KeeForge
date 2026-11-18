import XCTest
@testable import KeeForge

/// Graph policy and real URLSession transport coverage with isolated URLProtocol
/// responses and token acquisition; no live account or server is contacted.
final class OneDriveCloudProviderTests: XCTestCase {
    private let graphBase = "https://graph.microsoft.com/v1.0"

    func testCreationTokenFailureIsProvenBeforeContentDispatch() async throws {
        let provider = OneDriveCloudProvider(tokenProvider: { _ in throw CloudProviderError.notAuthenticated })
        do {
            _ = try await provider.createFile(accountId: "missing", path: "/vault.kdbx", data: Data([1]), progress: { _ in })
            XCTFail("Expected pre-dispatch failure")
        } catch let failure as CloudUploadFailure {
            XCTAssertEqual(failure.outcome, .notDispatched)
            XCTAssertEqual(failure.underlying, .notAuthenticated)
        }
    }

    @MainActor
    func testReplacementLostAcknowledgementsKeepOneAttemptAcrossSimpleAndChunkBoundaries() async throws {
        // Independent changed paths: conditional PUT, nil-rev PUT, final chunk 503 and lost chunk response.
        for scenario in [(32, true, false), (32, false, false), (5 * 1_024 * 1_024 + 1, true, false),
                         (OneDriveCloudProvider.simpleUploadByteLimit + 1, true, true)] {
            DatabaseListStore.clearAll()
            defer { DatabaseListStore.clearAll() }
            let probe = OneDriveHTTPProbe(firstFailure: 503, dropsResponse: scenario.2)
            defer { probe.close() }
            let provider = probe.provider()
            let reference = try! DatabaseListStore.addCloud(provider: provider.id, accountId: "probe",
                file: .init(id: "/probe.kdbx", name: "probe.kdbx", path: "/probe.kdbx", isFolder: false, modifiedDate: nil, size: nil))
            let context = try CloudJournalTestContext(reference: reference, payload: Data(repeating: 7, count: scenario.0))
            var environment = context.environment(transport: CloudJournalTransport(revision: scenario.1 ? "base-rev" : nil))
            environment.writeGuarantee = { _, rev, count in provider.writeGuarantee(expectedRev: rev, byteCount: count) }
            environment.revisionIdentifiesContent = { _, rev in provider.revisionIdentifiesContent(rev) }
            environment.upload = { _, bytes, rev, progress in
                try await provider.upload(accountId: "probe", fileId: "/probe.kdbx", data: bytes, expectedRev: rev, progress: progress)
            }
            do {
                _ = try await CloudDatabaseSaver.deliver(context.stored, reference: reference, environment: environment)
                XCTFail("Lost acknowledgement cannot settle or be retried internally")
            } catch { XCTAssertNil(error as? CloudUploadFailure, "Post-dispatch uncertainty is not rejection proof") }
            let retained = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
            XCTAssertEqual(CloudJournalDecision.state(of: retained.marker), .attempting)
            XCTAssertNotNil(retained.marker.uploadAttemptID)
            XCTAssertFalse(retained.marker.attemptIsFenced == true)
            let before = probe.puts
            XCTAssertEqual(before.count, scenario.0 > 5 * 1_024 * 1_024 ? 2 : 1)
            XCTAssertEqual(before.first?.value(forHTTPHeaderField: "If-Match"),
                scenario.0 <= OneDriveCloudProvider.simpleUploadByteLimit && scenario.1 ? "base-rev" : nil)
            for _ in 0..<2 {
                guard case .retained? = try await CloudDatabaseSaver.deliver(retained, reference: reference, environment: environment) else {
                    return XCTFail("An unresolved attempt must remain retained")
                }
            }
            XCTAssertEqual(probe.puts.count, before.count)
            XCTAssertEqual(probe.sessionStatusReads, 0, "Replacement cannot fall back to a possibly accepted range")
            XCTAssertEqual(probe.acceptedBytes, context.payload)
            XCTAssertFalse(CloudJournalDecision.permitsMutation([retained.marker], changingKey: true))
            XCTAssertFalse(DatabaseListStore.remove(id: reference.id))
            XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(retained), context.payload)
            XCTAssertEqual(try Data(contentsOf: context.cacheURL), context.payload)
        }
    }

    @MainActor
    func testSimplePut412AfterUnobservedCommitRemainsUncertain() async throws {
        DatabaseListStore.clearAll()
        defer { DatabaseListStore.clearAll() }
        let probe = OneDriveHTTPProbe(firstFailure: 412, commitBeforeFailure: true)
        defer { probe.close() }
        let provider = probe.provider()
        let reference = try! DatabaseListStore.addCloud(provider: provider.id, accountId: "probe",
            file: .init(id: "/probe.kdbx", name: "probe.kdbx", path: "/probe.kdbx", isFolder: false, modifiedDate: nil, size: nil))
        let context = try CloudJournalTestContext(reference: reference)
        var environment = context.environment()
        environment.upload = { _, bytes, rev, progress in
            try await provider.upload(accountId: "probe", fileId: "/probe.kdbx", data: bytes, expectedRev: rev, progress: progress)
        }
        do {
            _ = try await CloudDatabaseSaver.deliver(context.stored, reference: reference, environment: environment)
            XCTFail("Expected current-request rejection")
        } catch let failure as CloudUploadFailure { XCTAssertEqual(failure.outcome, .uncertain) }
        let retained = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        XCTAssertEqual(CloudJournalDecision.state(of: retained.marker), .attempting)
        XCTAssertFalse(retained.marker.attemptIsFenced == true)
        XCTAssertEqual(probe.puts.count, 1)
        XCTAssertEqual(probe.acceptedBytes, context.payload)
        guard case .retained? = try await CloudDatabaseSaver.deliver(retained, reference: reference, environment: environment) else {
            return XCTFail("An unobserved commit cannot be retried")
        }
        XCTAssertEqual(probe.puts.count, 1)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(retained), context.payload)
    }

    @MainActor
    func testReplacementAuthenticationFailureNeverDispatchesContentAndFencesOnlyItsAttempt() async throws {
        DatabaseListStore.clearAll()
        defer { DatabaseListStore.clearAll() }
        let probe = OneDriveHTTPProbe(firstFailure: nil)
        defer { probe.close() }
        let tokenCalls = CloudJournalEffectCounter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OneDriveProbeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = OneDriveCloudProvider(session: session, tokenProvider: { _ in
            tokenCalls.record()
            if tokenCalls.value == 1 { throw CloudProviderError.notAuthenticated }
            return probe.token
        })
        let reference = try! DatabaseListStore.addCloud(provider: provider.id, accountId: "probe",
            file: .init(id: "/probe.kdbx", name: "probe.kdbx", path: "/probe.kdbx", isFolder: false, modifiedDate: nil, size: nil))
        let context = try CloudJournalTestContext(reference: reference)
        var environment = context.environment()
        environment.upload = { _, bytes, rev, progress in
            try await provider.upload(accountId: "probe", fileId: "/probe.kdbx", data: bytes, expectedRev: rev, progress: progress)
        }
        do {
            _ = try await CloudDatabaseSaver.deliver(context.stored, reference: reference, environment: environment)
            XCTFail("Expected token acquisition failure")
        } catch let failure as CloudUploadFailure {
            XCTAssertEqual(failure.outcome, .notDispatched)
            XCTAssertEqual(failure.underlying, .notAuthenticated)
        }
        let ready = try XCTUnwrap(PendingUploadQueue.readJournal(for: reference.id).first)
        XCTAssertEqual(CloudJournalDecision.state(of: ready.marker), .ready)
        XCTAssertTrue(ready.marker.attemptIsFenced == true)
        XCTAssertTrue(probe.puts.isEmpty)
        XCTAssertEqual(try PendingUploadQueue.readImmutablePayload(ready), context.payload)
        guard case .saved? = try await CloudDatabaseSaver.deliver(ready, reference: reference, environment: environment) else {
            return XCTFail("A separately authenticated explicit attempt can deliver")
        }
        XCTAssertEqual(tokenCalls.value, 2)
        XCTAssertEqual(probe.puts.count, 1)
    }

    func testShippedCreateKeepsChunkRetryAndFailConflictBehavior() async throws {
        let probe = OneDriveHTTPProbe(firstFailure: 503)
        defer { probe.close() }
        let created = try await probe.provider().createFile(accountId: "probe", path: "/probe.kdbx", data: Data([1, 2, 3]), progress: { _ in })
        XCTAssertEqual(created.file.id, "/probe.kdbx")
        XCTAssertEqual(probe.puts.count, 2)
        XCTAssertEqual(probe.sessionStatusReads, 1)
        XCTAssertEqual(probe.conflictBehavior, "fail")
    }

    func testReplacementChunkSuccessCrossesBoundaryWithoutRetries() async throws {
        let probe = OneDriveHTTPProbe(firstFailure: nil)
        defer { probe.close() }
        let bytes = Data(repeating: 9, count: 5 * 1_024 * 1_024 + 1)
        _ = try await probe.provider().upload(accountId: "probe", fileId: "/probe.kdbx", data: bytes, expectedRev: "base-rev", progress: { _ in })
        XCTAssertEqual(probe.puts.count, 2)
        XCTAssertEqual(probe.acceptedBytes, bytes)
        XCTAssertEqual(probe.puts.last?.value(forHTTPHeaderField: "Content-Range"), "bytes 5242880-5242880/5242881")
        XCTAssertEqual(probe.conflictBehavior, "replace")
    }

    // MARK: - Graph URL construction

    // Regression: the path arrives already percent-encoded, and
    // `appendingPathComponent` used to encode it a second time
    // (`My%20Vault.kdbx` -> `My%2520Vault.kdbx`), so a database in a folder with
    // a space could neither be opened nor saved.

    func testContentURLKeepsSingleEncodingForSpace() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.contentPath(for: "/Apps/My Vault.kdbx")
        )

        XCTAssertEqual(
            url.absoluteString,
            "\(graphBase)/me/drive/root:/Apps/My%20Vault.kdbx:/content"
        )
        XCTAssertFalse(url.absoluteString.contains("%25"))
    }

    func testUploadSessionURLKeepsSingleEncodingForHashAndAmpersand() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.uploadSessionPath(for: "/My files/pass#1&2.kdbx")
        )

        XCTAssertEqual(
            url.absoluteString,
            "\(graphBase)/me/drive/root:/My%20files/pass%231%262.kdbx:/createUploadSession"
        )
        XCTAssertFalse(url.absoluteString.contains("%25"))
    }

    func testItemURLKeepsSingleEncodingForNonASCII() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.itemPath(for: "/Ünïcode/Käse.kdbx"),
            queryItems: [URLQueryItem(name: "$select", value: "id,name,size,eTag,cTag")]
        )

        XCTAssertEqual(
            url.absoluteString,
            "\(graphBase)/me/drive/root:/%C3%9Cn%C3%AFcode/K%C3%A4se.kdbx:?$select=id,name,size,eTag,cTag"
        )
        XCTAssertFalse(url.absoluteString.contains("%25"))
    }

    func testPercentNamesAreEncodedOnceForCreateOpenSaveAndList() throws {
        let path = "/Vaults%20 100%/new%20db 100%.kdbx"
        let encoded = "/Vaults%2520%20100%25/new%2520db%20100%25.kdbx"
        for (requestPath, suffix) in [
            (OneDriveCloudProvider.uploadSessionPath(for: path), ":/createUploadSession"),
            (OneDriveCloudProvider.contentPath(for: path), ":/content"),
            (OneDriveCloudProvider.itemPath(for: path), ":"),
            (OneDriveCloudProvider.listChildrenPath(for: path), ":/children"),
        ] {
            let url = try OneDriveCloudProvider.graphURL(path: requestPath)
            XCTAssertEqual(url.absoluteString, "\(graphBase)/me/drive/root:\(encoded)\(suffix)")
        }
    }

    func testPlainASCIIPathIsUnchanged() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.contentPath(for: "/Vaults/personal.kdbx")
        )

        XCTAssertEqual(
            url.absoluteString,
            "\(graphBase)/me/drive/root:/Vaults/personal.kdbx:/content"
        )
    }

    func testListChildrenURLPreservesSelectQueryItems() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.listChildrenPath(for: "/My files"),
            queryItems: [
                URLQueryItem(name: "$top", value: "200"),
                URLQueryItem(name: "$select", value: "id,name,size,eTag,cTag,lastModifiedDateTime,folder,file,parentReference"),
            ]
        )

        XCTAssertEqual(
            url.absoluteString,
            "\(graphBase)/me/drive/root:/My%20files:/children"
                + "?$top=200"
                + "&$select=id,name,size,eTag,cTag,lastModifiedDateTime,folder,file,parentReference"
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "$top" })?.value, "200")
    }

    func testDriveRootListingHasNoPathSegment() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.listChildrenPath(for: nil)
        )

        XCTAssertEqual(url.absoluteString, "\(graphBase)/me/drive/root/children")
    }

    // MARK: - Post-upload metadata re-read

    // Upload responses come in a different shape than the `$select`ed metadata
    // GET and can omit cTag/eTag/hashes, so `upload`/`createFile` re-read the
    // committed item and only fall back to the upload response when the
    // re-read fails (the upload has already committed by then).

    func testItemIdURLCarriesTheSharedMetadataSelectList() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.itemIdPath(for: "01BYE5RZ6QN3ZWBTUFOFD3GSPGOHDJD36K"),
            queryItems: [URLQueryItem(name: "$select", value: OneDriveCloudProvider.metadataSelectList)]
        )

        XCTAssertEqual(
            url.absoluteString,
            "\(graphBase)/me/drive/items/01BYE5RZ6QN3ZWBTUFOFD3GSPGOHDJD36K"
                + "?$select=id,name,size,eTag,cTag,lastModifiedDateTime,folder,file,parentReference"
        )
    }

    func testItemIdURLAcceptsPersonalDriveIdsContainingBang() throws {
        let url = try OneDriveCloudProvider.graphURL(
            path: OneDriveCloudProvider.itemIdPath(for: "F5E2A6C4D1B3!114")
        )

        XCTAssertEqual(url.absoluteString, "\(graphBase)/me/drive/items/F5E2A6C4D1B3!114")
    }

    func testResolveUploadMetadataReturnsTheAuthoritativeReRead() async {
        let fallback = CloudFileMetadata(
            modifiedDate: Date(timeIntervalSince1970: 100),
            contentHash: nil,
            size: 64,
            rev: nil
        )
        let authoritative = CloudFileMetadata(
            modifiedDate: Date(timeIntervalSince1970: 200),
            contentHash: "quickXor:full-hash",
            size: 64,
            rev: "cTag-full"
        )

        let resolved = await OneDriveCloudProvider.resolveUploadMetadata(fallback: fallback) {
            authoritative
        }

        XCTAssertEqual(resolved, authoritative)
    }

    func testResolveUploadMetadataFallsBackWhenTheReReadFails() async {
        // The upload already committed, so a failed re-read must not fail the
        // save; the upload response's metadata is returned instead.
        let fallback = CloudFileMetadata(
            modifiedDate: Date(timeIntervalSince1970: 100),
            contentHash: nil,
            size: 64,
            rev: "cTag-upload"
        )

        let resolved = await OneDriveCloudProvider.resolveUploadMetadata(fallback: fallback) {
            throw CloudProviderError.serviceUnavailable
        }

        XCTAssertEqual(resolved, fallback)
    }

    // MARK: - Content-hash tagging

    func testTaggedContentHashPrefersQuickXorAndTagsTheAlgorithm() {
        // quickXorHash is the only hash Graph guarantees on both Personal and
        // Business drives; the tag keeps two algorithms from comparing equal.
        XCTAssertEqual(
            OneDriveCloudProvider.taggedContentHash(quickXorHash: "QX==", sha1Hash: "SHA1HEX"),
            "quickXor:QX=="
        )
        XCTAssertEqual(
            OneDriveCloudProvider.taggedContentHash(quickXorHash: nil, sha1Hash: "SHA1HEX"),
            "sha1:SHA1HEX"
        )
        XCTAssertNil(OneDriveCloudProvider.taggedContentHash(quickXorHash: nil, sha1Hash: nil))
    }

    // MARK: - Simple-upload threshold

    func testSimpleUploadUsedJustBelowLimit() {
        XCTAssertTrue(
            OneDriveCloudProvider.shouldUseSimpleUpload(
                byteCount: OneDriveCloudProvider.simpleUploadByteLimit - 1
            )
        )
    }

    func testSimpleUploadUsedExactlyAtLimit() {
        XCTAssertTrue(
            OneDriveCloudProvider.shouldUseSimpleUpload(
                byteCount: OneDriveCloudProvider.simpleUploadByteLimit
            )
        )
    }

    func testSimpleUploadNotUsedJustAboveLimit() {
        XCTAssertFalse(
            OneDriveCloudProvider.shouldUseSimpleUpload(
                byteCount: OneDriveCloudProvider.simpleUploadByteLimit + 1
            )
        )
    }

    func testSimpleUploadLimitIsFourMebibytes() {
        XCTAssertEqual(OneDriveCloudProvider.simpleUploadByteLimit, 4 * 1_024 * 1_024)
    }

    // MARK: - Upload-session retry policy

    func testRetriesSpuriousInvalidRequest() {
        XCTAssertTrue(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 400,
                errorCode: "invalidRequest",
                attempt: 1
            )
        )
        // Graph is inconsistent about casing on this code.
        XCTAssertTrue(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 400,
                errorCode: "invalidrequest",
                attempt: 1
            )
        )
    }

    func testDoesNotRetryOtherBadRequests() {
        XCTAssertFalse(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 400,
                errorCode: "quotaLimitReached",
                attempt: 1
            )
        )
        XCTAssertFalse(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 400,
                errorCode: nil,
                attempt: 1
            )
        )
    }

    func testRetriesThrottlingAndServerErrors() {
        for statusCode in [429, 500, 502, 503, 504, 599] {
            XCTAssertTrue(
                OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                    statusCode: statusCode,
                    errorCode: nil,
                    attempt: 1
                ),
                "HTTP \(statusCode) should be retried"
            )
        }
    }

    func testNeverRetriesDeterministicFailures() {
        for statusCode in [401, 403, 404, 409, 412] {
            XCTAssertFalse(
                OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                    statusCode: statusCode,
                    errorCode: "invalidRequest",
                    attempt: 1
                ),
                "HTTP \(statusCode) must surface immediately"
            )
        }
    }

    func testAttemptCapStopsAtThreeTotalAttempts() {
        XCTAssertTrue(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 400,
                errorCode: "invalidRequest",
                attempt: 1
            )
        )
        XCTAssertTrue(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 400,
                errorCode: "invalidRequest",
                attempt: 2
            )
        )
        XCTAssertFalse(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 400,
                errorCode: "invalidRequest",
                attempt: OneDriveCloudProvider.uploadSessionCreationMaxAttempts
            )
        )
        XCTAssertFalse(
            OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                statusCode: 503,
                errorCode: nil,
                attempt: OneDriveCloudProvider.uploadSessionCreationMaxAttempts + 1
            )
        )
    }

    // MARK: - General request retry policy

    // Every operation, not just `createUploadSession`, now retries the
    // transient set. A single 503 used to fail a whole save.

    func testGeneralRequestsRetryThrottlingAndServerErrors() {
        for statusCode in [429, 500, 502, 503, 504] {
            XCTAssertTrue(
                OneDriveCloudProvider.shouldRetryRequest(statusCode: statusCode, attempt: 1),
                "HTTP \(statusCode) should be retried"
            )
        }
    }

    func testGeneralRequestsNeverRetryDeterministicFailures() {
        // Includes 412: retrying a precondition failure would paper over a
        // genuine remote change instead of surfacing the conflict.
        for statusCode in [400, 401, 403, 404, 409, 412, 416] {
            XCTAssertFalse(
                OneDriveCloudProvider.shouldRetryRequest(statusCode: statusCode, attempt: 1),
                "HTTP \(statusCode) must surface immediately"
            )
        }
    }

    func testGeneralRequestsStopAtThreeTotalAttempts() {
        XCTAssertTrue(OneDriveCloudProvider.shouldRetryRequest(statusCode: 503, attempt: 1))
        XCTAssertTrue(OneDriveCloudProvider.shouldRetryRequest(statusCode: 503, attempt: 2))
        XCTAssertFalse(
            OneDriveCloudProvider.shouldRetryRequest(
                statusCode: 503,
                attempt: OneDriveCloudProvider.requestMaxAttempts
            )
        )
    }

    func testSessionCreationRetryReusesTheGeneralPolicyOutsideBadRequests() {
        // The spurious-400 rule is the only difference between the two.
        for statusCode in [401, 403, 404, 409, 412, 429, 500, 503] {
            XCTAssertEqual(
                OneDriveCloudProvider.shouldRetryUploadSessionCreation(
                    statusCode: statusCode,
                    errorCode: "invalidRequest",
                    attempt: 1
                ),
                OneDriveCloudProvider.shouldRetryRequest(statusCode: statusCode, attempt: 1),
                "HTTP \(statusCode) should follow the shared policy"
            )
        }
    }

    // MARK: - Chunk retry policy

    func testChunkRetriesRangeAlreadySatisfied() {
        // 416 means the service already holds those bytes: resync the offset,
        // do not fail the save.
        XCTAssertTrue(OneDriveCloudProvider.shouldRetryUploadChunk(statusCode: 416, attempt: 1))
        XCTAssertTrue(OneDriveCloudProvider.shouldRetryUploadChunk(statusCode: 416, attempt: 2))
        XCTAssertFalse(
            OneDriveCloudProvider.shouldRetryUploadChunk(
                statusCode: 416,
                attempt: OneDriveCloudProvider.requestMaxAttempts
            )
        )
    }

    func testChunkRetriesTransientAndNotDeterministicFailures() {
        for statusCode in [429, 500, 503, 504] {
            XCTAssertTrue(
                OneDriveCloudProvider.shouldRetryUploadChunk(statusCode: statusCode, attempt: 1),
                "HTTP \(statusCode) should be retried"
            )
        }
        for statusCode in [401, 403, 404, 409, 412] {
            XCTAssertFalse(
                OneDriveCloudProvider.shouldRetryUploadChunk(statusCode: statusCode, attempt: 1),
                "HTTP \(statusCode) must surface immediately"
            )
        }
    }

    // MARK: - Resume offset from nextExpectedRanges

    func testResumeOffsetReadsOpenEndedRange() {
        XCTAssertEqual(
            OneDriveCloudProvider.resumeOffset(
                fromNextExpectedRanges: ["26-"],
                totalBytes: 128
            ),
            26
        )
    }

    func testResumeOffsetTakesLowestOfSeveralGaps() {
        // Graph does not promise to list every missing range, so the only safe
        // restart point is the lowest byte it admits to missing.
        XCTAssertEqual(
            OneDriveCloudProvider.resumeOffset(
                fromNextExpectedRanges: ["77829-99375", "12345-55232"],
                totalBytes: 100_000
            ),
            12_345
        )
    }

    func testResumeOffsetIgnoresOutOfBoundsAndGarbageRanges() {
        XCTAssertNil(
            OneDriveCloudProvider.resumeOffset(
                fromNextExpectedRanges: ["512-", "nonsense", "-"],
                totalBytes: 512
            )
        )
        XCTAssertEqual(
            OneDriveCloudProvider.resumeOffset(
                fromNextExpectedRanges: ["nonsense", "300-511"],
                totalBytes: 512
            ),
            300
        )
    }

    func testResumeOffsetIsNilWhenNothingIsMissing() {
        // An empty list means the payload is fully received; the caller keeps
        // its own offset rather than rewinding to zero.
        XCTAssertNil(
            OneDriveCloudProvider.resumeOffset(fromNextExpectedRanges: [], totalBytes: 128)
        )
    }

    // MARK: - Backoff

    func testBackoffGrowsBetweenAttempts() {
        let first = OneDriveCloudProvider.retryDelay(forAttempt: 1, retryAfter: nil)
        let second = OneDriveCloudProvider.retryDelay(forAttempt: 2, retryAfter: nil)

        XCTAssertEqual(first, .milliseconds(500))
        XCTAssertEqual(second, .milliseconds(1_500))
        XCTAssertLessThan(first, second)
    }

    func testRetryAfterHeaderWinsAndIsClamped() {
        XCTAssertEqual(
            OneDriveCloudProvider.retryDelay(forAttempt: 1, retryAfter: "2"),
            .seconds(2)
        )
        XCTAssertEqual(
            OneDriveCloudProvider.retryDelay(forAttempt: 1, retryAfter: "3600"),
            .seconds(10)
        )
    }

    func testUnparsableRetryAfterFallsBackToBackoff() {
        // HTTP-date form and garbage both fall back to the computed backoff.
        XCTAssertEqual(
            OneDriveCloudProvider.retryDelay(
                forAttempt: 2,
                retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT"
            ),
            .milliseconds(1_500)
        )
        XCTAssertEqual(
            OneDriveCloudProvider.retryDelay(forAttempt: 1, retryAfter: "-5"),
            .milliseconds(500)
        )
    }

    // MARK: - Graph error mapping

    // Regression: 403 used to always mean "reconnect for write scope", which
    // sends the user through a sign-in that fixes nothing when the real cause
    // is a permission on the item.

    func testAccessDeniedIsAPermissionProblemNotAScopeProblem() {
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 403,
                errorCode: "accessDenied",
                message: "Access denied."
            ),
            .permissionDenied
        )
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(statusCode: 403, errorCode: nil, message: nil),
            .permissionDenied
        )
    }

    func testScopeAndAuthFailuresKeepTheirRemedies() {
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 403,
                errorCode: "authorizationRequestDenied",
                message: "Insufficient privileges."
            ),
            .writeScopeRequired
        )
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 401,
                errorCode: "InvalidAuthenticationToken",
                message: "Access token has expired."
            ),
            .notAuthenticated
        )
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(statusCode: 401, errorCode: nil, message: nil),
            .notAuthenticated
        )
    }

    func testQuotaFailuresMapToInsufficientSpace() {
        // Docs use HTTP 507 and the `quotaLimitReached` code; the old check
        // looked for the English word "quota" inside a 400 message.
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(statusCode: 507, errorCode: nil, message: nil),
            .insufficientSpace
        )
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 400,
                errorCode: "quotaLimitReached",
                message: "The user has reached their quota limit."
            ),
            .insufficientSpace
        )
    }

    func testThrottlingAndServerErrorsMapToTypedCases() {
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(statusCode: 429, errorCode: nil, message: nil),
            .rateLimited
        )
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 429,
                errorCode: "activityLimitReached",
                message: "Throttled."
            ),
            .rateLimited
        )
        for statusCode in [500, 502, 503, 504] {
            XCTAssertEqual(
                OneDriveCloudProvider.mapGraphError(statusCode: statusCode, errorCode: nil, message: nil),
                .serviceUnavailable,
                "HTTP \(statusCode) should be a service outage"
            )
        }
    }

    func testNameConflictOnCreateStaysAConflict() {
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 409,
                errorCode: "nameAlreadyExists",
                message: "Another file exists with the same name."
            ),
            .conflict(remoteRev: nil)
        )
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(statusCode: 412, errorCode: nil, message: nil),
            .conflict(remoteRev: nil)
        )
    }

    func testNameShapedBadRequestMapsToInvalidName() {
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 400,
                errorCode: "invalidRequest",
                message: "The file name contains invalid characters."
            ),
            .invalidName
        )
    }

    func testUnclassifiedBadRequestKeepsTheServerMessage() {
        // The spurious `invalidRequest` has nothing to do with the name, so it
        // must not be relabeled once retries are exhausted.
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 400,
                errorCode: "invalidRequest",
                message: "The request is malformed or incorrect."
            ),
            .unknown("The request is malformed or incorrect.")
        )
        XCTAssertFalse(OneDriveCloudProvider.isNameShapedFailure(message: nil))
        XCTAssertFalse(
            OneDriveCloudProvider.isNameShapedFailure(message: "The request is malformed or incorrect.")
        )
    }

    func testItemNotFoundMapsToFileNotFound() {
        XCTAssertEqual(
            OneDriveCloudProvider.mapGraphError(
                statusCode: 404,
                errorCode: "itemNotFound",
                message: "Item does not exist."
            ),
            .fileNotFound
        )
    }

    // MARK: - Transport error mapping

    // Regression: the whole of NSURLErrorDomain used to collapse to "offline",
    // so a TLS failure told the user they had no network and quietly fell back
    // to the cached copy.

    func testConnectivityErrorsAreOffline() {
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorCannotFindHost] {
            let mapped = OneDriveCloudProvider.mapGenericError(
                NSError(domain: NSURLErrorDomain, code: code)
            )
            XCTAssertEqual(mapped as? CloudProviderError, .networkUnavailable, "code \(code)")
        }
    }

    func testTLSAndCancellationErrorsSurfaceAsThemselves() {
        for code in [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorCancelled] {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            let mapped = OneDriveCloudProvider.mapGenericError(error)
            XCTAssertNotEqual(mapped as? CloudProviderError, .networkUnavailable, "code \(code)")
            XCTAssertEqual(
                mapped as? CloudProviderError,
                .unknown(error.localizedDescription),
                "code \(code)"
            )
        }
    }

    func testNonURLErrorsKeepTheirDescription() {
        let error = NSError(
            domain: "com.example.Test",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Disk is on fire."]
        )

        XCTAssertEqual(
            OneDriveCloudProvider.mapGenericError(error) as? CloudProviderError,
            .unknown("Disk is on fire.")
        )
    }
}

extension OneDriveCloudProviderTests {
    func testNonKDBXFileIsListedOnlyWhenAllFilesAreRequested() throws {
        let item = try driveItem(#"{"id":"1","name":"vault.bin","file":{},"parentReference":{"path":"/drive/root:/Vaults"}}"#)

        XCTAssertNil(OneDriveCloudProvider.makeCloudFile(from: item, includesAllFiles: false))
        XCTAssertEqual(OneDriveCloudProvider.makeCloudFile(from: item, includesAllFiles: true)?.id, "/Vaults/vault.bin")
    }

    func testKDBXFilesAndFoldersAreListedEitherWay() throws {
        let database = try driveItem(#"{"id":"2","name":"Personal.KDBX","file":{}}"#)
        let folder = try driveItem(#"{"id":"3","name":"Vaults","folder":{}}"#)

        XCTAssertNotNil(OneDriveCloudProvider.makeCloudFile(from: database, includesAllFiles: false))
        XCTAssertEqual(OneDriveCloudProvider.makeCloudFile(from: folder, includesAllFiles: false)?.isFolder, true)
    }

    private func driveItem(_ json: String) throws -> OneDriveDriveItem {
        try JSONDecoder().decode(OneDriveDriveItem.self, from: Data(json.utf8))
    }
}

private final class OneDriveHTTPProbe: @unchecked Sendable {
    let token = UUID().uuidString
    let host = "onedrive-\(UUID().uuidString.lowercased()).invalid"
    private let lock = NSLock()
    private let firstFailure: Int?
    private let dropsResponse: Bool
    private let commitBeforeFailure: Bool
    private var failed = false
    private var requests: [URLRequest] = []
    private var accepted = Data()
    private var statusReads = 0
    private var behavior: String?
    private var session: URLSession?
    var puts: [URLRequest] { lock.withLock { requests.filter { $0.httpMethod == "PUT" } } }
    var acceptedBytes: Data { lock.withLock { accepted } }
    var sessionStatusReads: Int { lock.withLock { statusReads } }
    var conflictBehavior: String? { lock.withLock { behavior } }

    init(firstFailure: Int?, dropsResponse: Bool = false, commitBeforeFailure: Bool = false) {
        self.firstFailure = firstFailure
        self.dropsResponse = dropsResponse
        self.commitBeforeFailure = commitBeforeFailure
        OneDriveProbeURLProtocol.install(self)
    }

    func provider() -> OneDriveCloudProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OneDriveProbeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        self.session = session
        return OneDriveCloudProvider(session: session, tokenProvider: { [token] _ in token })
    }

    func close() { session?.invalidateAndCancel(); OneDriveProbeURLProtocol.remove(self) }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return bytes
    }

    func response(for request: URLRequest) throws -> (Int, Data) {
        try lock.withLock {
            requests.append(request)
            if request.httpMethod == "POST" {
                let json = try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any]
                behavior = (json?["item"] as? [String: Any])?["@microsoft.graph.conflictBehavior"] as? String
                return (200, Data("{\"uploadUrl\":\"https://\(host)/session\"}".utf8))
            }
            if request.httpMethod == "PUT" {
                let range = request.value(forHTTPHeaderField: "Content-Range")
                let body = Self.body(of: request)
                let final: Bool
                if let range, let total = range.split(separator: "/").last.flatMap({ Int($0) }) {
                    final = range.contains("-\(total - 1)/")
                } else { final = true }
                if !final { accepted.append(body); return (202, Data()) }
                if !failed, let firstFailure {
                    failed = true
                    if firstFailure != 412 || commitBeforeFailure { accepted.append(body) }
                    if dropsResponse { throw URLError(.networkConnectionLost) }
                    return (firstFailure, Data("{\"error\":{\"code\":\"\(firstFailure == 412 ? "preconditionFailed" : "serviceNotAvailable")\"}}".utf8))
                }
                if range == nil || accepted.count <= body.count { accepted = body } else { accepted.append(body) }
            }
            if request.httpMethod == "GET", request.url?.host == host {
                statusReads += 1
                return (200, Data(#"{"nextExpectedRanges":["0-"]}"#.utf8))
            }
            return (200, Data(#"{"id":"item-id","name":"probe.kdbx","cTag":"next-rev","file":{}}"#.utf8))
        }
    }
}

private final class OneDriveProbeURLProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var probes: [String: OneDriveHTTPProbe] = [:]
    }
    private static let registry = Registry()
    static func install(_ probe: OneDriveHTTPProbe) { registry.lock.withLock { registry.probes[probe.token] = probe } }
    static func remove(_ probe: OneDriveHTTPProbe) { registry.lock.withLock { _ = registry.probes.removeValue(forKey: probe.token) } }
    private static func probe(for request: URLRequest) -> OneDriveHTTPProbe? {
        registry.lock.withLock {
            registry.probes.values.first {
                request.value(forHTTPHeaderField: "Authorization") == "Bearer \($0.token)" || request.url?.host == $0.host
            }
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { probe(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let probe = Self.probe(for: request), let url = request.url else { throw URLError(.unsupportedURL) }
            let (status, data) = try probe.response(for: request)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
