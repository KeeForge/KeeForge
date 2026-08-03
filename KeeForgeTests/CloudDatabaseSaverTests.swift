import CryptoKit
import XCTest
@testable import KeeForge

final class CloudDatabaseSaverTests: XCTestCase {
    private let fixturePassword = "testpassword123"

    override func setUp() {
        super.setUp()
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
    }

    override func tearDown() {
        DatabaseListStore.clearAll()
        CloudAccountStore.clearAll()
        SharedVaultStore.clearBookmark()
        super.tearDown()
    }

    func testSaveHappyPathUploadsBytesUpdatesCacheAndMetadata() async throws {
        let reference = try makeCloudReference(remoteRev: "rev-A")
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Cloud Save Entry")
        let recorder = UploadRecorder()
        let uploadedMetadata = CloudFileMetadata(
            modifiedDate: Date(timeIntervalSince1970: 200),
            contentHash: "remote-hash-B",
            size: 512,
            rev: "rev-B"
        )
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 150),
                    contentHash: "remote-hash-A",
                    size: Int64(context.currentData.count),
                    rev: "rev-A"
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                return uploadedMetadata
            }
        )

        let result = try await CloudDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            expectedRev: "rev-A",
            environment: environment
        )

        guard case .saved(let newSHA512) = result else {
            XCTFail("Expected save to succeed.")
            return
        }

        let firstUploadCall = await recorder.firstCall()
        let uploadCall = try XCTUnwrap(firstUploadCall)
        let uploadCallCount = await recorder.callCount()
        let cachedData = try Data(contentsOf: cacheURL)
        let updatedReference = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        let backupURL = try XCTUnwrap(DatabaseListStore.recentBackups(for: reference).first)

        XCTAssertEqual(uploadCallCount, 1)
        XCTAssertEqual(uploadCall.expectedRev, "rev-A")
        XCTAssertEqual(cachedData, uploadCall.data)
        XCTAssertEqual(newSHA512, KDBXCrypto.sha512(uploadCall.data))
        XCTAssertEqual(updatedReference.cloudSyncMetadata?.remoteRev, "rev-B")
        XCTAssertEqual(updatedReference.cloudSyncMetadata?.remoteContentHash, "remote-hash-B")
        XCTAssertEqual(updatedReference.cloudSyncMetadata?.remoteModifiedAt, uploadedMetadata.modifiedDate)
        XCTAssertNotNil(updatedReference.cloudSyncMetadata?.lastSyncedAt)
        XCTAssertNil(updatedReference.cloudSyncMetadata?.lastSyncError)
        XCTAssertEqual(try Data(contentsOf: backupURL), context.currentData)
    }

    func testSaveTwofishDatabaseUploadsReparsableCipherPreservingBytes() async throws {
        let loaded = try KDBXCompatibilitySupport.load(
            .syntheticTwofish,
            bundle: Bundle(for: Self.self)
        )
        let reference = try makeCloudReference(remoteRev: "rev-A")
        try DatabaseListStore.cacheDatabaseCopy(loaded.sourceData, for: reference)
        let cleanDraft = DatabaseDraft(
            rootGroup: loaded.rootGroup,
            meta: loaded.meta,
            sessionKey: loaded.sessionKey
        )
        let parentGroupID = TestDatabaseSupport.visibleRootGroupID(in: loaded.rootGroup)
        let dirtyDraft = try cleanDraft.apply(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(title: "Twofish Cloud Entry", password: "twofish-secret")
            )
        )
        let recorder = UploadRecorder()
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 150),
                    contentHash: "remote-hash-A",
                    size: Int64(loaded.sourceData.count),
                    rev: "rev-A"
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                return CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 200),
                    contentHash: "remote-hash-B",
                    size: Int64(data.count),
                    rev: "rev-B"
                )
            }
        )

        _ = try await CloudDatabaseSaver.save(
            draft: dirtyDraft,
            reference: reference,
            compositeKey: loaded.compositeKey,
            openTimeSHA512: KDBXCrypto.sha512(loaded.sourceData),
            expectedRev: "rev-A",
            environment: environment
        )

        let uploadCall = await recorder.firstCall()
        let uploaded = try XCTUnwrap(uploadCall?.data)
        let reparsed = try KDBXParser.parseWithMetaAndHeader(
            data: uploaded,
            compositeKey: loaded.compositeKey,
            sessionKey: loaded.sessionKey
        )
        XCTAssertEqual(reparsed.header.cipherID, KDBXParser.twofishCipherUUID)
        XCTAssertTrue(reparsed.rootGroup.allEntries.contains { $0.title == "Twofish Cloud Entry" })
        XCTAssertEqual(try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference)), uploaded)
    }

    func testSaveRevChangedRemotelyReturnsConflictDoesNotWriteCache() async throws {
        let reference = try makeCloudReference(remoteRev: "rev-A")
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Remote Conflict Entry")
        let recorder = UploadRecorder()
        let remoteData = Data("remote-cloud-copy".utf8)
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 150),
                    contentHash: "remote-hash-A",
                    size: Int64(context.currentData.count),
                    rev: "rev-A"
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                throw CloudProviderError.conflict(remoteRev: "rev-B")
            },
            downloadRemoteData: { _ in remoteData }
        )

        let result = try await CloudDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            expectedRev: "rev-A",
            environment: environment
        )

        guard case .conflict(let remoteSHA512, let conflictData) = result else {
            XCTFail("Expected save conflict.")
            return
        }

        let uploadCallCount = await recorder.callCount()

        XCTAssertEqual(uploadCallCount, 1)
        XCTAssertEqual(remoteSHA512, KDBXCrypto.sha512(remoteData))
        XCTAssertEqual(conflictData, remoteData)
        XCTAssertEqual(try Data(contentsOf: cacheURL), context.currentData)
        // The pre-save backup is written before the upload, so a conflicting
        // upload still leaves a backup of the pre-save local bytes behind.
        let backupURL = try XCTUnwrap(DatabaseListStore.recentBackups(for: reference).first)
        XCTAssertEqual(try Data(contentsOf: backupURL), context.currentData)
    }

    func testSaveRemoteRevChangedBeforeUploadReturnsConflictWithoutUploadAttempt() async throws {
        let reference = try makeCloudReference(remoteRev: "rev-A")
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Metadata Conflict Entry")
        let recorder = UploadRecorder()
        let remoteData = Data("remote-newer-rev".utf8)
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 175),
                    contentHash: "remote-hash-B",
                    size: 256,
                    rev: "rev-B"
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                return CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 200),
                    contentHash: "remote-hash-C",
                    size: Int64(data.count),
                    rev: "rev-C"
                )
            },
            downloadRemoteData: { _ in remoteData }
        )

        let result = try await CloudDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            expectedRev: "rev-A",
            environment: environment
        )

        guard case .conflict(let remoteSHA512, let conflictData) = result else {
            XCTFail("Expected save conflict.")
            return
        }

        let uploadCallCount = await recorder.callCount()

        XCTAssertEqual(uploadCallCount, 0)
        XCTAssertEqual(remoteSHA512, KDBXCrypto.sha512(remoteData))
        XCTAssertEqual(conflictData, remoteData)
        XCTAssertEqual(try Data(contentsOf: cacheURL), context.currentData)
        XCTAssertTrue(DatabaseListStore.recentBackups(for: reference).isEmpty)
    }

    // MARK: - Stale-tag phantom-conflict guard

    // Revision tags can go stale without any real remote edit (OneDrive
    // rewrites cTag/eTag after async post-processing). A remote whose bytes
    // are identical to the opened copy has no conflict to resolve, so the
    // saver rebases onto the fresh rev instead of surfacing a phantom alert.

    func testSaveStaleRevWithByteIdenticalRemoteProceedsWithFreshRev() async throws {
        let reference = try makeCloudReference(remoteRev: "rev-A")
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Stale Tag Entry")
        let recorder = UploadRecorder()
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 160),
                    contentHash: "remote-hash-B",
                    size: Int64(context.currentData.count),
                    rev: "rev-B"
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                return CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 200),
                    contentHash: "remote-hash-C",
                    size: Int64(data.count),
                    rev: "rev-C"
                )
            },
            downloadRemoteData: { _ in context.currentData }
        )

        let result = try await CloudDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            expectedRev: "rev-A",
            environment: environment
        )

        guard case .saved = result else {
            XCTFail("A stale rev over byte-identical remote content must not conflict.")
            return
        }

        let firstUploadCall = await recorder.firstCall()
        let uploadCall = try XCTUnwrap(firstUploadCall)
        let uploadCallCount = await recorder.callCount()
        let updatedReference = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))

        XCTAssertEqual(uploadCallCount, 1)
        XCTAssertEqual(uploadCall.expectedRev, "rev-B", "The save must rebase onto the fresh rev.")
        XCTAssertEqual(updatedReference.cloudSyncMetadata?.remoteRev, "rev-C")
    }

    /// Reproduces the original OneDrive failure directly: upload responses
    /// stripped of rev and hash while `getMetadata` reports the server's own
    /// tag. The second save in a session must still succeed.
    func testSecondSaveSucceedsWhenUploadResponsesAreStrippedOfRevAndHash() async throws {
        var reference = try makeCloudReference(remoteRev: "rev-A")
        let initialData = try Data(contentsOf: DatabaseListStore.cacheLocation(for: reference))
        let recorder = UploadRecorder()
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 160),
                    contentHash: "quickXor:server-hash",
                    size: Int64(initialData.count),
                    rev: "rev-server"
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                return CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 200),
                    contentHash: nil,
                    size: Int64(data.count),
                    rev: nil
                )
            },
            downloadRemoteData: { _ in
                // The remote holds whatever was uploaded last.
                await recorder.lastCall()?.data ?? initialData
            }
        )

        for index in 0..<2 {
            let cacheURL = DatabaseListStore.cacheLocation(for: reference)
            let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Stripped Metadata Entry \(index)")

            let result = try await CloudDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512,
                expectedRev: reference.expectedCloudRevision,
                environment: environment
            )

            guard case .saved = result else {
                XCTFail("Save \(index) must succeed despite stripped upload metadata.")
                return
            }

            reference = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        }

        let uploadCallCount = await recorder.callCount()
        let recordedLastCall = await recorder.lastCall()
        let lastUploadCall = try XCTUnwrap(recordedLastCall)
        XCTAssertEqual(uploadCallCount, 2)
        XCTAssertEqual(lastUploadCall.expectedRev, "rev-server")
    }

    func testSaveUploadConflictWithByteIdenticalRemoteRetriesOnceWithRefreshedRev() async throws {
        let reference = try makeCloudReference(remoteRev: "rev-A")
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Stale 412 Entry")
        let recorder = UploadRecorder()
        // Pre-check sees the recorded rev; the post-412 refresh sees the
        // mutated one.
        let revisions = RevisionSequence(["rev-A", "rev-B"])
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 150),
                    contentHash: "remote-hash-A",
                    size: Int64(context.currentData.count),
                    rev: await revisions.next()
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                if await recorder.callCount() == 1 {
                    throw CloudProviderError.conflict(remoteRev: "rev-B")
                }
                return CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 200),
                    contentHash: "remote-hash-C",
                    size: Int64(data.count),
                    rev: "rev-C"
                )
            },
            downloadRemoteData: { _ in context.currentData }
        )

        let result = try await CloudDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            expectedRev: "rev-A",
            environment: environment
        )

        guard case .saved = result else {
            XCTFail("A 412 over byte-identical remote content must retry and succeed.")
            return
        }

        let uploadCallCount = await recorder.callCount()
        let recordedRetryCall = await recorder.lastCall()
        let retryCall = try XCTUnwrap(recordedRetryCall)
        XCTAssertEqual(uploadCallCount, 2)
        XCTAssertEqual(retryCall.expectedRev, "rev-B", "The retry must carry the refreshed rev.")
    }

    func testSaveUploadConflictRetryAlsoConflictingStopsAfterExactlyOneRetry() async throws {
        let reference = try makeCloudReference(remoteRev: "rev-A")
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Persistent 412 Entry")
        let recorder = UploadRecorder()
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 150),
                    contentHash: "remote-hash-A",
                    size: Int64(context.currentData.count),
                    rev: "rev-A"
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                throw CloudProviderError.conflict(remoteRev: "rev-B")
            },
            downloadRemoteData: { _ in context.currentData }
        )

        let result = try await CloudDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            expectedRev: "rev-A",
            environment: environment
        )

        guard case .conflict(let remoteSHA512, let conflictData) = result else {
            XCTFail("A conflict that survives one guarded retry must surface as a conflict.")
            return
        }

        let uploadCallCount = await recorder.callCount()
        XCTAssertEqual(uploadCallCount, 2, "Exactly one retry, never a loop.")
        XCTAssertEqual(remoteSHA512, KDBXCrypto.sha512(context.currentData))
        XCTAssertEqual(conflictData, context.currentData)
    }

    func testSaveLocalCacheChangedSinceOpenReturnsConflictBeforeUploadAttempted() async throws {
        let reference = try makeCloudReference(remoteRev: "rev-A")
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Local Conflict Entry")
        let recorder = UploadRecorder()
        let locallyChangedData = Data("cache-changed-after-open".utf8)
        try locallyChangedData.write(to: cacheURL, options: .atomic)
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 150),
                    contentHash: "remote-hash-A",
                    size: 256,
                    rev: "rev-A"
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                return CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 200),
                    contentHash: "remote-hash-B",
                    size: Int64(data.count),
                    rev: "rev-B"
                )
            }
        )

        let result = try await CloudDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            expectedRev: "rev-A",
            environment: environment
        )

        guard case .conflict(let remoteSHA512, let conflictData) = result else {
            XCTFail("Expected save conflict.")
            return
        }

        let uploadCallCount = await recorder.callCount()

        XCTAssertEqual(uploadCallCount, 0)
        XCTAssertEqual(remoteSHA512, KDBXCrypto.sha512(locallyChangedData))
        XCTAssertEqual(conflictData, locallyChangedData)
        XCTAssertEqual(try Data(contentsOf: cacheURL), locallyChangedData)
        XCTAssertTrue(DatabaseListStore.recentBackups(for: reference).isEmpty)
    }

    func testSaveWriteScopeMissingThrowsWriteScopeRequired() async throws {
        let reference = try makeCloudReference(remoteRev: "rev-A")
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Write Scope Entry")
        let recorder = UploadRecorder()
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 150),
                    contentHash: "remote-hash-A",
                    size: Int64(context.currentData.count),
                    rev: "rev-A"
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                throw CloudProviderError.writeScopeRequired
            }
        )

        do {
            _ = try await CloudDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512,
                expectedRev: "rev-A",
                environment: environment
            )
            XCTFail("Expected save to throw a write-scope error.")
        } catch let error as CloudProviderError {
            XCTAssertEqual(error, .writeScopeRequired)
        }

        let uploadCallCount = await recorder.callCount()

        XCTAssertEqual(uploadCallCount, 1)
        XCTAssertEqual(try Data(contentsOf: cacheURL), context.currentData)
        // The pre-save backup is written before the upload, so a failed upload
        // still leaves a backup of the pre-save local bytes behind.
        let backupURL = try XCTUnwrap(DatabaseListStore.recentBackups(for: reference).first)
        XCTAssertEqual(try Data(contentsOf: backupURL), context.currentData)
    }

    func testSaveNetworkFailureDoesNotCorruptCache() async throws {
        let reference = try makeCloudReference(remoteRev: "rev-A")
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Offline Save Entry")
        let recorder = UploadRecorder()
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 150),
                    contentHash: "remote-hash-A",
                    size: Int64(context.currentData.count),
                    rev: "rev-A"
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(0.5)
                throw CloudProviderError.networkUnavailable
            }
        )

        do {
            _ = try await CloudDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512,
                expectedRev: "rev-A",
                environment: environment
            )
            XCTFail("Expected save to throw on network failure.")
        } catch let error as CloudProviderError {
            XCTAssertEqual(error, .networkUnavailable)
        }

        let uploadCallCount = await recorder.callCount()

        XCTAssertEqual(uploadCallCount, 1)
        XCTAssertEqual(try Data(contentsOf: cacheURL), context.currentData)
        // The pre-save backup is written before the upload, so a failed upload
        // still leaves a backup of the pre-save local bytes behind.
        let backupURL = try XCTUnwrap(DatabaseListStore.recentBackups(for: reference).first)
        XCTAssertEqual(try Data(contentsOf: backupURL), context.currentData)
    }

    func testSaveSavesBackupLikeLocalSaverAndPrunesToFiveNewest() async throws {
        var reference = try makeCloudReference(remoteRev: "rev-0")
        let dates = TestDateSequence(
            dates: (0..<7).map { Date(timeIntervalSince1970: 1_000 + Double($0)) }
        )

        var priorVersions: [Data] = []
        for index in 0..<7 {
            let currentReference = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
            let cacheURL = DatabaseListStore.cacheLocation(for: currentReference)
            let context = try makeDirtySaveContext(
                cacheURL: cacheURL,
                entryTitle: "Prune Cloud Entry \(index)"
            )
            priorVersions.append(context.currentData)
            let nextRev = "rev-\(index + 1)"
            let environment = makeEnvironment(
                getMetadata: { reference in
                    CloudFileMetadata(
                        modifiedDate: Date(timeIntervalSince1970: 100 + Double(index)),
                        contentHash: "remote-hash-\(index)",
                        size: Int64(context.currentData.count),
                        rev: reference.expectedCloudRevision
                    )
                },
                upload: { _, data, expectedRev, progress in
                    progress(1)
                    return CloudFileMetadata(
                        modifiedDate: Date(timeIntervalSince1970: 200 + Double(index)),
                        contentHash: "remote-hash-\(index + 1)",
                        size: Int64(data.count),
                        rev: nextRev
                    )
                },
                now: {
                    dates.next()
                }
            )

            let result = try await CloudDatabaseSaver.save(
                draft: context.draft,
                reference: currentReference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512,
                expectedRev: currentReference.expectedCloudRevision,
                environment: environment
            )

            guard case .saved = result else {
                XCTFail("Expected save \(index) to succeed.")
                return
            }

            reference = try XCTUnwrap(DatabaseListStore.databases.first(where: { $0.id == reference.id }))
        }

        let backups = DatabaseListStore.recentBackups(for: reference)
        let backupContents = try backups.map { try Data(contentsOf: $0) }

        XCTAssertEqual(backups.count, 5)
        XCTAssertEqual(backupContents, Array(priorVersions.suffix(5).reversed()))
    }

    func testSaveLegacyKDBX31ThrowsDatabaseIsReadOnlyBeforeUpload() async throws {
        let reference = try makeCloudReference(remoteRev: "rev-A", fixtureName: "test-v3-backup")
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Legacy Cloud Save")
        let recorder = UploadRecorder()
        let environment = makeEnvironment(
            getMetadata: { reference in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 150),
                    contentHash: "remote-hash-A",
                    size: Int64(context.currentData.count),
                    rev: reference.expectedCloudRevision
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                return CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 200),
                    contentHash: "remote-hash-B",
                    size: Int64(data.count),
                    rev: "rev-B"
                )
            }
        )

        do {
            _ = try await CloudDatabaseSaver.save(
                draft: context.draft,
                reference: reference,
                compositeKey: context.compositeKey,
                openTimeSHA512: context.openTimeSHA512,
                expectedRev: "rev-A",
                environment: environment
            )
            XCTFail("Expected legacy KDBX3 cloud save to stay read-only.")
        } catch let error as SaveError {
            XCTAssertEqual(error, .databaseIsReadOnly)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let uploadCallCount = await recorder.callCount()
        XCTAssertEqual(uploadCallCount, 0)
        XCTAssertEqual(try Data(contentsOf: cacheURL), context.currentData)
    }

    // MARK: - Rekey (change master key, #59)

    func testRekeySaveUploadsBytesEncryptedWithNewKey() async throws {
        let reference = try makeCloudReference(remoteRev: "rev-A")
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Cloud Rekey Entry")
        let newPassword = "rotated-master-123"
        let newCompositeKey = try KDBXCrypto.compositeKey(password: newPassword, keyFileData: nil)
        let recorder = UploadRecorder()
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 150),
                    contentHash: "remote-hash-A",
                    size: Int64(context.currentData.count),
                    rev: "rev-A"
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                return CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 200),
                    contentHash: "remote-hash-B",
                    size: Int64(data.count),
                    rev: "rev-B"
                )
            }
        )

        let result = try await CloudDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            expectedRev: "rev-A",
            kdfPolicy: .mainApp,
            newCompositeKey: newCompositeKey,
            environment: environment
        )

        guard case .saved = result else {
            XCTFail("Expected rekey save to succeed.")
            return
        }

        let uploadCall = await recorder.firstCall()
        let uploaded = try XCTUnwrap(uploadCall?.data)
        let reparsed = try KDBXParser.parseWithMeta(
            data: uploaded,
            password: newPassword,
            sessionKey: SymmetricKey(size: .bits256)
        )
        XCTAssertTrue(reparsed.rootGroup.allEntries.contains { $0.title == "Cloud Rekey Entry" })
        XCTAssertThrowsError(
            try KDBXParser.parseWithMeta(
                data: uploaded,
                password: fixturePassword,
                sessionKey: SymmetricKey(size: .bits256)
            ),
            "The old credentials must no longer open the uploaded bytes."
        )
        XCTAssertEqual(try Data(contentsOf: cacheURL), uploaded)
    }

    func testRekeySaveConflictAbortsWithoutUpload() async throws {
        let reference = try makeCloudReference(remoteRev: "rev-A")
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Cloud Rekey Conflict Entry")
        let recorder = UploadRecorder()
        let remoteData = Data("remote-moved-during-rekey".utf8)
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 175),
                    contentHash: "remote-hash-B",
                    size: 256,
                    rev: "rev-B"
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                return CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 200),
                    contentHash: "remote-hash-C",
                    size: Int64(data.count),
                    rev: "rev-C"
                )
            },
            downloadRemoteData: { _ in remoteData }
        )

        let result = try await CloudDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            expectedRev: "rev-A",
            kdfPolicy: .mainApp,
            newCompositeKey: try KDBXCrypto.compositeKey(password: "rotated-master-123", keyFileData: nil),
            environment: environment
        )

        guard case .conflict = result else {
            XCTFail("Expected the rekey save to conflict.")
            return
        }

        let uploadCallCount = await recorder.callCount()
        XCTAssertEqual(uploadCallCount, 0)
        XCTAssertEqual(try Data(contentsOf: cacheURL), context.currentData)
        XCTAssertTrue(DatabaseListStore.recentBackups(for: reference).isEmpty)
    }

    // MARK: - Saves with no recorded revision (M4)

    func testSaveWithoutRecordedRevConflictsWhenRemoteContentHashMoved() async throws {
        let reference = try makeCloudReference(remoteRev: nil, remoteContentHash: "remote-hash-A")
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Legacy Reference Entry")
        let recorder = UploadRecorder()
        let remoteData = Data("remote-moved-on".utf8)
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 175),
                    contentHash: "remote-hash-B",
                    size: 256,
                    rev: nil
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                return CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 200),
                    contentHash: "remote-hash-C",
                    size: Int64(data.count),
                    rev: nil
                )
            },
            downloadRemoteData: { _ in remoteData }
        )

        let result = try await CloudDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            expectedRev: nil,
            environment: environment
        )

        guard case .conflict(let remoteSHA512, let conflictData) = result else {
            XCTFail("Expected a nil-rev save against a moved remote to conflict.")
            return
        }

        let uploadCallCount = await recorder.callCount()

        XCTAssertEqual(uploadCallCount, 0)
        XCTAssertEqual(remoteSHA512, KDBXCrypto.sha512(remoteData))
        XCTAssertEqual(conflictData, remoteData)
        XCTAssertEqual(try Data(contentsOf: cacheURL), context.currentData)
    }

    func testSaveWithoutRecordedRevUploadsWhenRemoteContentHashStillMatches() async throws {
        let reference = try makeCloudReference(remoteRev: nil, remoteContentHash: "remote-hash-A")
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Legacy Match Entry")
        let recorder = UploadRecorder()
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 150),
                    contentHash: "remote-hash-A",
                    size: Int64(context.currentData.count),
                    rev: nil
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                return CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 200),
                    contentHash: "remote-hash-B",
                    size: Int64(data.count),
                    rev: nil
                )
            }
        )

        let result = try await CloudDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            expectedRev: nil,
            environment: environment
        )

        guard case .saved = result else {
            XCTFail("Expected a nil-rev save against an unchanged remote to succeed.")
            return
        }

        let uploadCallCount = await recorder.callCount()
        XCTAssertEqual(uploadCallCount, 1)
    }

    func testSaveWithoutRecordedRevConflictsWhenRemoteReportsUnseenRevision() async throws {
        let reference = try makeCloudReference(remoteRev: nil, remoteContentHash: nil)
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Unseen Revision Entry")
        let recorder = UploadRecorder()
        let remoteData = Data("remote-with-etag".utf8)
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 175),
                    contentHash: nil,
                    size: 256,
                    rev: "\"etag-we-never-recorded\""
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                return CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 200),
                    contentHash: nil,
                    size: Int64(data.count),
                    rev: "\"etag-B\""
                )
            },
            downloadRemoteData: { _ in remoteData }
        )

        let result = try await CloudDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            expectedRev: nil,
            environment: environment
        )

        guard case .conflict = result else {
            XCTFail("Expected a remote reporting an unrecorded revision to be treated as conflict-suspect.")
            return
        }

        let uploadCallCount = await recorder.callCount()
        XCTAssertEqual(uploadCallCount, 0)
    }

    /// The documented residue: a WebDAV server exposing neither an ETag nor a
    /// content hash offers nothing to verify against, so saves must keep
    /// working there rather than conflicting on every attempt.
    func testSaveAgainstProviderWithoutRevOrContentHashStillUploads() async throws {
        let reference = try makeCloudReference(remoteRev: nil, remoteContentHash: nil)
        let cacheURL = DatabaseListStore.cacheLocation(for: reference)
        let context = try makeDirtySaveContext(cacheURL: cacheURL, entryTitle: "Bare WebDAV Entry")
        let recorder = UploadRecorder()
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 150),
                    contentHash: nil,
                    size: Int64(context.currentData.count),
                    rev: nil
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                return CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 200),
                    contentHash: nil,
                    size: Int64(data.count),
                    rev: nil
                )
            }
        )

        let result = try await CloudDatabaseSaver.save(
            draft: context.draft,
            reference: reference,
            compositeKey: context.compositeKey,
            openTimeSHA512: context.openTimeSHA512,
            expectedRev: nil,
            environment: environment
        )

        guard case .saved = result else {
            XCTFail("A provider without revisions or content hashes must still be savable.")
            return
        }

        let uploadCallCount = await recorder.callCount()
        let uploadedBytes = await recorder.firstCall()?.data
        XCTAssertEqual(uploadCallCount, 1)
        XCTAssertEqual(try Data(contentsOf: cacheURL), uploadedBytes)
    }

    func testPushPendingUploadWithoutExpectedRevConflictsWhenRemoteContentHashMoved() async throws {
        let reference = try makeCloudReference(remoteRev: nil, remoteContentHash: "remote-hash-A")
        let recorder = UploadRecorder()
        let environment = makeEnvironment(
            getMetadata: { _ in
                CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 175),
                    contentHash: "remote-hash-B",
                    size: 256,
                    rev: nil
                )
            },
            upload: { _, data, expectedRev, progress in
                await recorder.record(data: data, expectedRev: expectedRev)
                progress(1)
                return CloudFileMetadata(
                    modifiedDate: Date(timeIntervalSince1970: 200),
                    contentHash: "remote-hash-C",
                    size: Int64(data.count),
                    rev: nil
                )
            }
        )

        let result = try await CloudDatabaseSaver.pushPendingUpload(
            reference: reference,
            encryptedBytes: Data("autofill-bytes".utf8),
            expectedRev: nil,
            environment: environment
        )

        guard case .conflict = result else {
            XCTFail("A legacy marker must not blind-overwrite a moved remote.")
            return
        }

        let uploadCallCount = await recorder.callCount()
        XCTAssertEqual(uploadCallCount, 0)
    }

    func testRemoteHasDivergedComparesRevExactlyWhenOneWasRecorded() {
        let recorded = makeRecordedMetadata(rev: "rev-A", contentHash: "hash-A")

        XCTAssertFalse(
            CloudDatabaseSaver.remoteHasDiverged(
                recorded: recorded,
                remote: CloudFileMetadata(modifiedDate: .now, contentHash: "hash-Z", size: 1, rev: "rev-A"),
                expectedRev: "rev-A"
            ),
            "A matching rev decides the question on its own; the hash is not consulted."
        )
        XCTAssertTrue(
            CloudDatabaseSaver.remoteHasDiverged(
                recorded: recorded,
                remote: CloudFileMetadata(modifiedDate: .now, contentHash: "hash-A", size: 1, rev: "rev-B"),
                expectedRev: "rev-A"
            )
        )
        XCTAssertTrue(
            CloudDatabaseSaver.remoteHasDiverged(
                recorded: recorded,
                remote: CloudFileMetadata(modifiedDate: .now, contentHash: "hash-A", size: 1, rev: nil),
                expectedRev: "rev-A"
            )
        )
    }

    func testRemoteHasDivergedFallsBackToContentHashWhenNoRevWasRecorded() {
        XCTAssertFalse(
            CloudDatabaseSaver.remoteHasDiverged(
                recorded: makeRecordedMetadata(rev: nil, contentHash: "hash-A"),
                remote: CloudFileMetadata(modifiedDate: .now, contentHash: "hash-A", size: 1, rev: nil),
                expectedRev: nil
            )
        )
        XCTAssertTrue(
            CloudDatabaseSaver.remoteHasDiverged(
                recorded: makeRecordedMetadata(rev: nil, contentHash: "hash-A"),
                remote: CloudFileMetadata(modifiedDate: .now, contentHash: "hash-B", size: 1, rev: nil),
                expectedRev: nil
            )
        )
        XCTAssertTrue(
            CloudDatabaseSaver.remoteHasDiverged(
                recorded: makeRecordedMetadata(rev: nil, contentHash: nil),
                remote: CloudFileMetadata(modifiedDate: .now, contentHash: "hash-A", size: 1, rev: nil),
                expectedRev: nil
            ),
            "Remote reports a hash we never recorded, so we have not seen these bytes."
        )
        XCTAssertFalse(
            CloudDatabaseSaver.remoteHasDiverged(
                recorded: makeRecordedMetadata(rev: nil, contentHash: nil),
                remote: CloudFileMetadata(modifiedDate: .now, contentHash: nil, size: 1, rev: nil),
                expectedRev: nil
            ),
            "Bare WebDAV residue: nothing to verify against, so the save proceeds."
        )
    }

    private func makeRecordedMetadata(rev: String?, contentHash: String?) -> CloudSyncMetadata {
        CloudSyncMetadata(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            fileId: "/Vaults/cloud-save.kdbx",
            displayPath: "/Vaults/cloud-save.kdbx",
            remoteContentHash: contentHash,
            remoteModifiedAt: Date(timeIntervalSince1970: 100),
            remoteRev: rev,
            lastSyncedAt: nil,
            lastSyncError: nil
        )
    }

    private func makeEnvironment(
        getMetadata: @escaping @Sendable (DatabaseReference) async throws -> CloudFileMetadata,
        upload: @escaping @Sendable (DatabaseReference, Data, String?, CloudDatabaseSaver.ProgressHandler) async throws -> CloudFileMetadata,
        downloadRemoteData: @escaping @Sendable (DatabaseReference) async throws -> Data = { _ in
            throw TestError.unexpectedRemoteDownload
        },
        now: @escaping @Sendable () -> Date = { .now }
    ) -> CloudDatabaseSaver.Environment {
        var environment = CloudDatabaseSaver.Environment.live
        environment.beginBackgroundTask = { _ in .invalid }
        environment.endBackgroundTask = { _ in }
        environment.getMetadata = getMetadata
        environment.upload = upload
        environment.downloadRemoteData = downloadRemoteData
        environment.now = now
        return environment
    }

    /// `remoteContentHash` defaults to one derived from the revision, which is
    /// what the rev-carrying cases want. The nil-rev cases set it explicitly,
    /// because there the hash is the only thing the divergence gate can use.
    private func makeCloudReference(
        remoteRev: String?,
        remoteContentHash: String? = nil,
        fixtureName: String = "test"
    ) throws -> DatabaseReference {
        let file = CloudFile(
            id: "/Vaults/cloud-save.kdbx",
            name: "cloud-save.kdbx",
            path: "/Vaults/cloud-save.kdbx",
            isFolder: false,
            modifiedDate: Date(timeIntervalSince1970: 100),
            size: 128
        )
        var reference = DatabaseListStore.addCloud(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "acct-1",
            file: file
        )
        reference.updateCloudSyncMetadata { metadata in
            metadata.remoteContentHash = remoteContentHash ?? remoteRev.map { "remote-hash-\($0)" }
            metadata.remoteModifiedAt = Date(timeIntervalSince1970: 100)
            metadata.remoteRev = remoteRev
        }
        DatabaseListStore.update(reference)
        try DatabaseListStore.cacheDatabaseCopy(try Data(contentsOf: fixtureURL(named: fixtureName)), for: reference)
        return reference
    }

    private func makeDirtySaveContext(
        cacheURL: URL,
        entryTitle: String
    ) throws -> CloudSaveContext {
        let currentData = try Data(contentsOf: cacheURL)
        let sessionKey = SymmetricKey(size: .bits256)
        let parsed = try KDBXParser.parseWithMeta(
            data: currentData,
            password: fixturePassword,
            sessionKey: sessionKey
        )
        let cleanDraft = DatabaseDraft(
            rootGroup: parsed.rootGroup,
            meta: parsed.meta,
            sessionKey: sessionKey
        )
        let parentGroupID = TestDatabaseSupport.visibleRootGroupID(in: parsed.rootGroup)
        let dirtyDraft = try cleanDraft.apply(
            .createEntry(
                parentGroupID: parentGroupID,
                draft: EntryDraftPayload(
                    title: entryTitle,
                    password: "secret-\(entryTitle)"
                )
            )
        )

        return CloudSaveContext(
            draft: dirtyDraft,
            compositeKey: KDBXCrypto.compositeKey(password: fixturePassword),
            openTimeSHA512: KDBXCrypto.sha512(currentData),
            currentData: currentData
        )
    }

    private func fixtureURL(named name: String = "test") throws -> URL {
        try TestDatabaseSupport.fixtureURL(named: name, bundle: Bundle(for: CloudDatabaseSaverTests.self))
    }
}

private struct CloudSaveContext {
    let draft: DatabaseDraft
    let compositeKey: Data
    let openTimeSHA512: Data
    let currentData: Data
}

private enum TestError: Error {
    case unexpectedRemoteDownload
}

private actor UploadRecorder {
    struct Call: Sendable {
        let data: Data
        let expectedRev: String?
    }

    private var calls: [Call] = []

    func record(data: Data, expectedRev: String?) {
        calls.append(Call(data: data, expectedRev: expectedRev))
    }

    func firstCall() -> Call? {
        calls.first
    }

    func lastCall() -> Call? {
        calls.last
    }

    func callCount() -> Int {
        calls.count
    }
}

private actor RevisionSequence {
    private var revisions: [String]

    init(_ revisions: [String]) {
        self.revisions = revisions
    }

    func next() -> String {
        revisions.count > 1 ? revisions.removeFirst() : revisions[0]
    }
}

private final class TestDateSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return dates.removeFirst()
    }
}
