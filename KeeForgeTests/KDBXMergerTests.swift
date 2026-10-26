import CryptoKit
import XCTest
@testable import KeeForge

/// Synthetic, in-memory merge scenarios. The oracle fixtures produced by
/// `keepassxc-cli merge` are exercised separately; these pin the behavior the
/// engine is specified to have, including the places KeeForge deliberately
/// deviates from KeePassXC's default (non-Synchronize) mode.
final class KDBXMergerTests: XCTestCase {
    private let sessionKey = SymmetricKey(size: .bits256)

    private let rootID = UUID()
    private let workID = UUID()
    private let personalID = UUID()
    private let alphaID = UUID()
    private let betaID = UUID()

    // MARK: - Matching and placement

    func test_merge_reorderOnlyEditWinsAndRetainsPriorOrderInHistory() throws {
        var old = try makeEntry(id: alphaID, title: "Fields", modified: time(10))
        old.customFields = ["Alpha": "a", "Zulu": "z"]
        old.customFieldOrder = ["Alpha", "Zulu"]
        var new = old
        new.customFieldOrder = ["Zulu", "Alpha"]
        new.lastModificationTime = time(20)
        let local = try makeSide(work: [old])
        let remote = try makeSide(work: [new])
        let merged = try mergedResult(local: local, remote: remote)
        let entry = try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertEqual(entry.customFieldOrder, ["Zulu", "Alpha"])
        XCTAssertEqual(entry.history.first?.customFieldOrder, ["Alpha", "Zulu"])
        let repeated = try mergedResult(local: .init(rootGroup: merged.rootGroup, meta: merged.meta), remote: remote)
        XCTAssertFalse(repeated.summary.hasChanges)
    }

    func test_merge_addsRemoteOnlyEntry() throws {
        let local = try makeSide(work: [makeEntry(id: alphaID, title: "Alpha", modified: time(10))])
        let remote = try makeSide(work: [
            makeEntry(id: alphaID, title: "Alpha", modified: time(10)),
            makeEntry(id: betaID, title: "Beta", modified: time(20)),
        ])

        let merged = try mergedResult(local: local, remote: remote)

        let work = try XCTUnwrap(findGroup(workID, in: merged.rootGroup))
        XCTAssertEqual(work.entries.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(merged.summary.entriesAdded, 1)
        XCTAssertTrue(merged.summary.hasChanges)
    }

    func test_merge_addsRemoteOnlyGroupWithItsEntry() throws {
        let newGroupID = UUID()
        let local = try makeSide(work: [makeEntry(id: alphaID, title: "Alpha", modified: time(10))])
        let remoteRoot = try makeTree(
            work: [makeEntry(id: alphaID, title: "Alpha", modified: time(10))],
            extraGroups: [
                KPGroup(
                    id: newGroupID,
                    name: "Remote Only",
                    entries: [try makeEntry(id: betaID, title: "Beta", modified: time(20))],
                    creationTime: time(20),
                    lastModificationTime: time(20),
                    locationChanged: time(20)
                )
            ]
        )
        let remote = KDBXMerger.Side(rootGroup: remoteRoot, meta: KPMeta())

        let merged = try mergedResult(local: local, remote: remote)

        let added = try XCTUnwrap(findGroup(newGroupID, in: merged.rootGroup))
        XCTAssertEqual(added.name, "Remote Only")
        XCTAssertEqual(added.entries.map(\.title), ["Beta"])
        XCTAssertEqual(merged.summary.groupsAdded, 1)
        XCTAssertEqual(merged.summary.entriesAdded, 1)
    }

    func test_merge_graftedNodesKeepUnknownXMLVerbatim() throws {
        let fragment = OpaqueXMLNodes(nodes: [
            .init(insertionIndex: 3, xml: "<ForegroundColor>#FF0000</ForegroundColor>")
        ])
        let local = try makeSide(work: [makeEntry(id: alphaID, title: "Alpha", modified: time(10))])
        var remoteBeta = try makeEntry(id: betaID, title: "Beta", modified: time(20))
        remoteBeta.unknownXML = fragment
        let remote = try makeSide(work: [
            makeEntry(id: alphaID, title: "Alpha", modified: time(10)),
            remoteBeta,
        ])

        let merged = try mergedResult(local: local, remote: remote)

        let beta = try XCTUnwrap(findEntry(betaID, in: merged.rootGroup))
        XCTAssertEqual(beta.unknownXML, fragment)
    }

    // MARK: - Entry conflicts

    func test_merge_newerRemoteEntryWins_andPushesLocalVersionToHistory() throws {
        let local = try makeSide(work: [makeEntry(id: alphaID, title: "Local Alpha", modified: time(10))])
        let remote = try makeSide(work: [makeEntry(id: alphaID, title: "Remote Alpha", modified: time(20))])

        let merged = try mergedResult(local: local, remote: remote)

        let alpha = try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertEqual(alpha.title, "Remote Alpha")
        XCTAssertEqual(alpha.lastModificationTime, time(20))
        XCTAssertEqual(alpha.history.map(\.title), ["Local Alpha"])
        XCTAssertEqual(merged.summary.entriesUpdated, 1)
        XCTAssertEqual(merged.summary.historyItemsAdded, 1)
    }

    func test_merge_newerLocalEntryWins_andPushesRemoteVersionToHistory() throws {
        let local = try makeSide(work: [makeEntry(id: alphaID, title: "Local Alpha", modified: time(30))])
        let remote = try makeSide(work: [makeEntry(id: alphaID, title: "Remote Alpha", modified: time(20))])

        let merged = try mergedResult(local: local, remote: remote)

        let alpha = try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertEqual(alpha.title, "Local Alpha")
        XCTAssertEqual(alpha.history.map(\.title), ["Remote Alpha"])
        XCTAssertEqual(merged.summary.entriesUpdated, 0)
        XCTAssertEqual(merged.summary.historyItemsAdded, 1)
    }

    func test_merge_equalTimestampsWithDifferentContent_keepsLocalAndPushesNothing() throws {
        let local = try makeSide(work: [makeEntry(id: alphaID, title: "Local Alpha", modified: time(20))])
        let remote = try makeSide(work: [makeEntry(id: alphaID, title: "Remote Alpha", modified: time(20))])

        let merged = try mergedResult(local: local, remote: remote)

        let alpha = try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertEqual(alpha.title, "Local Alpha")
        XCTAssertTrue(alpha.history.isEmpty)
        XCTAssertFalse(merged.summary.hasChanges)
    }

    func test_merge_subSecondTimestampDifferenceCountsAsEqual() throws {
        let local = try makeSide(work: [makeEntry(id: alphaID, title: "Local Alpha", modified: time(20))])
        let remote = try makeSide(work: [
            makeEntry(id: alphaID, title: "Remote Alpha", modified: time(20).addingTimeInterval(0.9))
        ])

        let merged = try mergedResult(local: local, remote: remote)

        let alpha = try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertEqual(alpha.title, "Local Alpha")
        XCTAssertFalse(merged.summary.hasChanges)
    }

    func test_merge_equalProtectedValuesUnderDifferentCiphertextAreNotAConflict() throws {
        var localAlpha = try makeEntry(id: alphaID, title: "Alpha", modified: time(10))
        localAlpha.password = try EncryptedValue.encrypt("s3cret", using: sessionKey)
        var remoteAlpha = try makeEntry(id: alphaID, title: "Alpha", modified: time(20))
        remoteAlpha.password = try EncryptedValue.encrypt("s3cret", using: sessionKey)
        XCTAssertNotEqual(localAlpha.password.sealedData, remoteAlpha.password.sealedData)

        let merged = try mergedResult(
            local: try makeSide(work: [localAlpha]),
            remote: try makeSide(work: [remoteAlpha])
        )

        let alpha = try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertTrue(alpha.history.isEmpty)
        XCTAssertEqual(merged.summary.entriesUpdated, 0)
        XCTAssertEqual(merged.summary.historyItemsAdded, 0)
    }

    func test_merge_differingProtectedValuesAreAConflict() throws {
        var localAlpha = try makeEntry(id: alphaID, title: "Alpha", modified: time(10))
        localAlpha.password = try EncryptedValue.encrypt("local", using: sessionKey)
        var remoteAlpha = try makeEntry(id: alphaID, title: "Alpha", modified: time(20))
        remoteAlpha.password = try EncryptedValue.encrypt("remote", using: sessionKey)

        let merged = try mergedResult(
            local: try makeSide(work: [localAlpha]),
            remote: try makeSide(work: [remoteAlpha])
        )

        let alpha = try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertEqual(try alpha.password.decrypt(using: sessionKey), "remote")
        XCTAssertEqual(alpha.history.count, 1)
        XCTAssertEqual(try alpha.history[0].password.decrypt(using: sessionKey), "local")
    }

    // MARK: - History union

    func test_merge_historyUnion_keepsOneVersionPerTimestampInChronologicalOrder() throws {
        var localAlpha = try makeEntry(id: alphaID, title: "Alpha v3", modified: time(30))
        localAlpha.history = [
            try makeEntry(id: alphaID, title: "Alpha v2", modified: time(20)),
            try makeEntry(id: alphaID, title: "Alpha v1", modified: time(10)),
        ]
        var remoteAlpha = try makeEntry(id: alphaID, title: "Alpha v3", modified: time(30))
        remoteAlpha.history = [
            try makeEntry(id: alphaID, title: "Alpha v1", modified: time(10)),
            try makeEntry(id: alphaID, title: "Alpha remote-only", modified: time(25)),
        ]

        let merged = try mergedResult(
            local: try makeSide(work: [localAlpha]),
            remote: try makeSide(work: [remoteAlpha])
        )

        let alpha = try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertEqual(alpha.history.map(\.title), ["Alpha v1", "Alpha v2", "Alpha remote-only"])
        XCTAssertEqual(merged.summary.historyItemsAdded, 1)
    }

    func test_merge_historyUnion_reappliesHistoryMaxItems() throws {
        var localAlpha = try makeEntry(id: alphaID, title: "Alpha v4", modified: time(40))
        localAlpha.history = [try makeEntry(id: alphaID, title: "Alpha v1", modified: time(10))]
        var remoteAlpha = try makeEntry(id: alphaID, title: "Alpha v4", modified: time(40))
        remoteAlpha.history = [
            try makeEntry(id: alphaID, title: "Alpha v2", modified: time(20)),
            try makeEntry(id: alphaID, title: "Alpha v3", modified: time(30)),
        ]

        var meta = KPMeta()
        meta.historyMaxItems = 2
        let merged = try mergedResult(
            local: KDBXMerger.Side(rootGroup: try makeTree(work: [localAlpha]), meta: meta),
            remote: KDBXMerger.Side(rootGroup: try makeTree(work: [remoteAlpha]), meta: meta)
        )

        let alpha = try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertEqual(alpha.history.map(\.title), ["Alpha v2", "Alpha v3"])
    }

    func test_merge_leavesUntouchedHistoryOrderAlone() throws {
        var localAlpha = try makeEntry(id: alphaID, title: "Alpha v3", modified: time(30))
        localAlpha.history = [
            try makeEntry(id: alphaID, title: "Alpha v2", modified: time(20)),
            try makeEntry(id: alphaID, title: "Alpha v1", modified: time(10)),
        ]
        let remoteAlpha = localAlpha

        let merged = try mergedResult(
            local: try makeSide(work: [localAlpha]),
            remote: try makeSide(work: [remoteAlpha])
        )

        let alpha = try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertEqual(alpha.history.map(\.title), ["Alpha v2", "Alpha v1"])
        XCTAssertFalse(merged.summary.hasChanges)
    }

    // MARK: - Moves

    func test_merge_remoteMoveWinsAndKeepsLocalEdit() throws {
        let localAlpha = try makeEntry(
            id: alphaID,
            title: "Locally Edited",
            modified: time(30),
            locationChanged: time(5)
        )
        let remoteAlpha = try makeEntry(
            id: alphaID,
            title: "Alpha",
            modified: time(10),
            locationChanged: time(20)
        )

        let merged = try mergedResult(
            local: try makeSide(work: [localAlpha]),
            remote: try makeSide(work: [], personal: [remoteAlpha])
        )

        let personal = try XCTUnwrap(findGroup(personalID, in: merged.rootGroup))
        let work = try XCTUnwrap(findGroup(workID, in: merged.rootGroup))
        XCTAssertEqual(personal.entries.map(\.id), [alphaID])
        XCTAssertTrue(work.entries.isEmpty)
        XCTAssertEqual(personal.entries[0].title, "Locally Edited")
        XCTAssertEqual(personal.entries[0].locationChanged, time(20))
        XCTAssertEqual(personal.entries[0].history.map(\.title), ["Alpha"])
        XCTAssertEqual(merged.summary.entriesMoved, 1)
    }

    func test_merge_nilLocalLocationChangedLosesToRemote() throws {
        let localAlpha = try makeEntry(id: alphaID, title: "Alpha", modified: time(10), locationChanged: nil)
        let remoteAlpha = try makeEntry(id: alphaID, title: "Alpha", modified: time(10), locationChanged: time(20))

        let merged = try mergedResult(
            local: try makeSide(work: [localAlpha]),
            remote: try makeSide(work: [], personal: [remoteAlpha])
        )

        let personal = try XCTUnwrap(findGroup(personalID, in: merged.rootGroup))
        XCTAssertEqual(personal.entries.map(\.id), [alphaID])
        XCTAssertEqual(merged.summary.entriesMoved, 1)
    }

    func test_merge_nilRemoteLocationChangedNeverMoves() throws {
        let localAlpha = try makeEntry(id: alphaID, title: "Alpha", modified: time(10), locationChanged: time(5))
        let remoteAlpha = try makeEntry(id: alphaID, title: "Alpha", modified: time(10), locationChanged: nil)

        let merged = try mergedResult(
            local: try makeSide(work: [localAlpha]),
            remote: try makeSide(work: [], personal: [remoteAlpha])
        )

        let work = try XCTUnwrap(findGroup(workID, in: merged.rootGroup))
        XCTAssertEqual(work.entries.map(\.id), [alphaID])
        XCTAssertEqual(work.entries[0].locationChanged, time(5))
        XCTAssertEqual(merged.summary.entriesMoved, 0)
    }

    func test_merge_movesEntryIntoGroupThatOnlyExistsRemotely() throws {
        let newGroupID = UUID()
        let local = try makeSide(work: [makeEntry(id: alphaID, title: "Alpha", modified: time(10))])
        let remoteRoot = try makeTree(
            work: [],
            extraGroups: [
                KPGroup(
                    id: newGroupID,
                    name: "Remote Only",
                    entries: [
                        try makeEntry(id: alphaID, title: "Alpha", modified: time(10), locationChanged: time(20))
                    ],
                    creationTime: time(20),
                    lastModificationTime: time(20),
                    locationChanged: time(20)
                )
            ]
        )

        let merged = try mergedResult(
            local: local,
            remote: KDBXMerger.Side(rootGroup: remoteRoot, meta: KPMeta())
        )

        let added = try XCTUnwrap(findGroup(newGroupID, in: merged.rootGroup))
        XCTAssertEqual(added.entries.map(\.id), [alphaID])
        XCTAssertEqual(merged.summary.groupsAdded, 1)
        XCTAssertEqual(merged.summary.entriesMoved, 1)
        XCTAssertEqual(merged.summary.entriesAdded, 0)
    }

    func test_merge_groupRenameFollowsLastModificationTime() throws {
        let localRoot = try makeTree(work: [])
        let remoteRoot = try makeTree(work: [])
        let remoteWork = try XCTUnwrap(findGroup(workID, in: remoteRoot))
        remoteWork.name = "Renamed Work"
        remoteWork.lastModificationTime = time(50)

        let merged = try mergedResult(
            local: KDBXMerger.Side(rootGroup: localRoot, meta: KPMeta()),
            remote: KDBXMerger.Side(rootGroup: remoteRoot, meta: KPMeta())
        )

        XCTAssertEqual(try XCTUnwrap(findGroup(workID, in: merged.rootGroup)).name, "Renamed Work")
        XCTAssertEqual(merged.summary.groupsUpdated, 1)
        XCTAssertEqual(merged.summary.groupsMoved, 0)
    }

    func test_merge_remoteGroupMoveReparentsSubtree() throws {
        let childID = UUID()
        let localRoot = try makeTree(work: [], extraGroups: [
            KPGroup(id: childID, name: "Child", creationTime: time(1), lastModificationTime: time(1), locationChanged: time(1))
        ])
        let remoteRoot = try makeTree(work: [])
        let remoteWork = try XCTUnwrap(findGroup(workID, in: remoteRoot))
        remoteWork.groups.append(
            KPGroup(id: childID, name: "Child", creationTime: time(1), lastModificationTime: time(1), locationChanged: time(40))
        )

        let merged = try mergedResult(
            local: KDBXMerger.Side(rootGroup: localRoot, meta: KPMeta()),
            remote: KDBXMerger.Side(rootGroup: remoteRoot, meta: KPMeta())
        )

        let work = try XCTUnwrap(findGroup(workID, in: merged.rootGroup))
        XCTAssertEqual(work.groups.map(\.id), [childID])
        XCTAssertFalse(merged.rootGroup.groups.contains { $0.id == childID })
        XCTAssertEqual(merged.summary.groupsMoved, 1)
    }

    // MARK: - Deletions

    func test_merge_deleteAfterEdit_removesObjectAndKeepsTombstone() throws {
        let local = try makeSide(work: [makeEntry(id: alphaID, title: "Alpha", modified: time(10))])
        var remoteMeta = KPMeta()
        remoteMeta.deletedObjects = [KPDeletedObject(uuid: alphaID, deletionTime: time(20))]
        let remote = KDBXMerger.Side(rootGroup: try makeTree(work: []), meta: remoteMeta)

        let merged = try mergedResult(local: local, remote: remote)

        XCTAssertNil(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertEqual(merged.meta.deletedObjects.map(\.uuid), [alphaID])
        XCTAssertEqual(merged.summary.deletionsApplied, 1)
        XCTAssertEqual(merged.summary.tombstonesAdded, 1)
    }

    func test_merge_editAfterDelete_resurrectsObjectAndDropsTombstone() throws {
        var localMeta = KPMeta()
        localMeta.deletedObjects = [KPDeletedObject(uuid: alphaID, deletionTime: time(20))]
        let local = KDBXMerger.Side(rootGroup: try makeTree(work: []), meta: localMeta)
        let remote = try makeSide(work: [makeEntry(id: alphaID, title: "Edited After Delete", modified: time(30))])

        let merged = try mergedResult(local: local, remote: remote)

        let alpha = try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertEqual(alpha.title, "Edited After Delete")
        XCTAssertTrue(merged.meta.deletedObjects.isEmpty)
        XCTAssertEqual(merged.summary.tombstonesDropped, 1)
        XCTAssertEqual(merged.summary.deletionsApplied, 0)
    }

    func test_merge_deletionAtTheSameSecondAsTheEditStillDeletes() throws {
        let local = try makeSide(work: [makeEntry(id: alphaID, title: "Alpha", modified: time(20))])
        var remoteMeta = KPMeta()
        remoteMeta.deletedObjects = [KPDeletedObject(uuid: alphaID, deletionTime: time(20))]
        let remote = KDBXMerger.Side(rootGroup: try makeTree(work: []), meta: remoteMeta)

        let merged = try mergedResult(local: local, remote: remote)

        XCTAssertNil(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertEqual(merged.summary.deletionsApplied, 1)
    }

    /// A remote that still carries a locally deleted object grafts it in and
    /// the deletion pass kills it again. The merged tree equals local, so the
    /// merge must report no change — otherwise every save conflict would offer
    /// a merge that changes nothing and the pair would never settle.
    func test_merge_objectGraftedAndDeletedInTheSameRunIsNotAChange() throws {
        var localMeta = KPMeta()
        localMeta.deletedObjects = [KPDeletedObject(uuid: alphaID, deletionTime: time(30))]
        let local = KDBXMerger.Side(rootGroup: try makeTree(work: []), meta: localMeta)
        let remote = try makeSide(work: [makeEntry(id: alphaID, title: "Alpha", modified: time(10))])

        let merged = try mergedResult(local: local, remote: remote)

        XCTAssertNil(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertEqual(merged.meta.deletedObjects.map(\.uuid), [alphaID])
        XCTAssertEqual(merged.summary.entriesAdded, 0)
        XCTAssertEqual(merged.summary.deletionsApplied, 0)
        XCTAssertFalse(merged.summary.hasChanges)
    }

    func test_merge_groupDeletionCascadesOnlyThroughEmptyGroups() throws {
        let doomedID = UUID()
        let localRoot = try makeTree(work: [], extraGroups: [
            KPGroup(
                id: doomedID,
                name: "Doomed",
                entries: [try makeEntry(id: betaID, title: "Survivor", modified: time(60))],
                creationTime: time(1),
                lastModificationTime: time(1),
                locationChanged: time(1)
            )
        ])
        var remoteMeta = KPMeta()
        remoteMeta.deletedObjects = [KPDeletedObject(uuid: doomedID, deletionTime: time(50))]

        let survived = try mergedResult(
            local: KDBXMerger.Side(rootGroup: localRoot, meta: KPMeta()),
            remote: KDBXMerger.Side(rootGroup: try makeTree(work: []), meta: remoteMeta)
        )

        XCTAssertNotNil(findGroup(doomedID, in: survived.rootGroup))
        // The surviving content also retires the tombstone (KeePassXC's
        // Synchronize rule): a tombstone left behind next to a live group
        // would delete it as soon as a later merge emptied it.
        XCTAssertTrue(survived.meta.deletedObjects.isEmpty)
        XCTAssertEqual(survived.summary.deletionsApplied, 0)

        let emptyLocalRoot = try makeTree(work: [], extraGroups: [
            KPGroup(
                id: doomedID,
                name: "Doomed",
                creationTime: time(1),
                lastModificationTime: time(1),
                locationChanged: time(1)
            )
        ])
        let removed = try mergedResult(
            local: KDBXMerger.Side(rootGroup: emptyLocalRoot, meta: KPMeta()),
            remote: KDBXMerger.Side(rootGroup: try makeTree(work: []), meta: remoteMeta)
        )

        XCTAssertNil(findGroup(doomedID, in: removed.rootGroup))
        XCTAssertEqual(removed.summary.deletionsApplied, 1)
    }

    func test_merge_groupDeletionCascadesAfterItsEntriesDie() throws {
        let doomedID = UUID()
        let localRoot = try makeTree(work: [], extraGroups: [
            KPGroup(
                id: doomedID,
                name: "Doomed",
                entries: [try makeEntry(id: betaID, title: "Doomed Entry", modified: time(10))],
                creationTime: time(1),
                lastModificationTime: time(1),
                locationChanged: time(1)
            )
        ])
        var remoteMeta = KPMeta()
        remoteMeta.deletedObjects = [
            KPDeletedObject(uuid: betaID, deletionTime: time(50)),
            KPDeletedObject(uuid: doomedID, deletionTime: time(50)),
        ]

        let merged = try mergedResult(
            local: KDBXMerger.Side(rootGroup: localRoot, meta: KPMeta()),
            remote: KDBXMerger.Side(rootGroup: try makeTree(work: []), meta: remoteMeta)
        )

        XCTAssertNil(findGroup(doomedID, in: merged.rootGroup))
        XCTAssertNil(findEntry(betaID, in: merged.rootGroup))
        XCTAssertEqual(merged.summary.deletionsApplied, 2)
        XCTAssertEqual(Set(merged.meta.deletedObjects.map(\.uuid)), [betaID, doomedID])
    }

    func test_merge_tombstoneUnionKeepsTheEarliestDeletionTime() throws {
        let ghostID = UUID()
        var localMeta = KPMeta()
        localMeta.deletedObjects = [KPDeletedObject(uuid: ghostID, deletionTime: time(50))]
        var remoteMeta = KPMeta()
        remoteMeta.deletedObjects = [KPDeletedObject(uuid: ghostID, deletionTime: time(30))]

        let merged = try mergedResult(
            local: KDBXMerger.Side(rootGroup: try makeTree(work: []), meta: localMeta),
            remote: KDBXMerger.Side(rootGroup: try makeTree(work: []), meta: remoteMeta)
        )

        XCTAssertEqual(merged.meta.deletedObjects.count, 1)
        XCTAssertEqual(merged.meta.deletedObjects[0].deletionTime, time(30))
    }

    // MARK: - Recycle bin

    func test_merge_entryRecoveryReferenceFollowsLocationInsteadOfContent() throws {
        let references = [
            OpaqueXMLNodes.empty,
            OpaqueXMLNodes(nodes: [.init(insertionIndex: 2, xml: "<PreviousParentGroup>\n\(workID.kdbxBase64String)\n</PreviousParentGroup>")]),
            OpaqueXMLNodes(nodes: [.init(insertionIndex: 2, xml: "<PreviousParentGroup>foreign-invalid-reference</PreviousParentGroup>")]),
        ]
        for remoteLocationWins in [false, true] {
            for remoteContentWins in [false, true] {
                for reference in references {
                    var localEntry = try makeEntry(id: alphaID, title: "Local", modified: time(remoteContentWins ? 10 : 20),
                                                   locationChanged: time(remoteLocationWins ? 5 : 30))
                    var remoteEntry = try makeEntry(id: alphaID, title: "Remote", modified: time(remoteContentWins ? 20 : 10),
                                                    locationChanged: time(remoteLocationWins ? 30 : 5))
                    let stale = PreviousParentGroupXML.setting(personalID, in: .empty, newInsertionIndex: 2)
                    localEntry.unknownXML = remoteLocationWins ? stale : reference
                    remoteEntry.unknownXML = remoteLocationWins ? reference : stale
                    localEntry.unknownXML.append(xml: "<ForegroundColor>local</ForegroundColor>", insertionIndex: 3)
                    remoteEntry.unknownXML.append(xml: "<ForegroundColor>remote</ForegroundColor>", insertionIndex: 3)
                    let local = try makeSide(work: remoteLocationWins ? [localEntry] : [], personal: remoteLocationWins ? [] : [localEntry])
                    let remote = try makeSide(work: remoteLocationWins ? [] : [remoteEntry], personal: remoteLocationWins ? [remoteEntry] : [])

                    let merged = try mergedResult(local: local, remote: remote)
                    let entry = try XCTUnwrap(findGroup(personalID, in: merged.rootGroup)?.entries.first)
                    XCTAssertEqual(entry.title, remoteContentWins ? "Remote" : "Local")
                    XCTAssertEqual(entry.locationChanged, time(30))
                    XCTAssertEqual(entry.unknownXML.nodes.filter { $0.elementName == "PreviousParentGroup" }, reference.nodes)
                    XCTAssertEqual(entry.unknownXML.nodes.filter { $0.elementName == "ForegroundColor" }.map(\.xml),
                                   ["<ForegroundColor>\(remoteContentWins ? "remote" : "local")</ForegroundColor>"])
                    XCTAssertEqual(local.rootGroup.allEntries.first?.unknownXML, localEntry.unknownXML)
                    XCTAssertEqual(remote.rootGroup.allEntries.first?.unknownXML, remoteEntry.unknownXML)
                    let second = try mergedResult(local: .init(rootGroup: merged.rootGroup, meta: merged.meta), remote: remote)
                    XCTAssertFalse(second.summary.hasChanges)
                    XCTAssertEqual(findEntry(alphaID, in: second.rootGroup)?.unknownXML, entry.unknownXML)
                }
            }
        }
    }

    func test_merge_groupRecoveryReferenceFollowsLocationInsteadOfScalars() throws {
        let childID = UUID()
        for remoteLocationWins in [false, true] {
            for remoteContentWins in [false, true] {
                for hasReference in [false, true] {
                    let local = try makeSide(work: [])
                    let remote = try makeSide(work: [])
                    let localGroup = KPGroup(id: childID, name: "Local", entries: [try makeEntry(id: alphaID, title: "Alpha", modified: time(1))],
                                             lastModificationTime: time(remoteContentWins ? 10 : 20), locationChanged: time(remoteLocationWins ? 5 : 30))
                    let remoteGroup = localGroup.deepCopy()
                    remoteGroup.name = "Remote"
                    remoteGroup.lastModificationTime = time(remoteContentWins ? 20 : 10)
                    remoteGroup.locationChanged = time(remoteLocationWins ? 30 : 5)
                    let reference = hasReference ? PreviousParentGroupXML.setting(workID, in: .empty, newInsertionIndex: 2) : .empty
                    let stale = PreviousParentGroupXML.setting(personalID, in: .empty, newInsertionIndex: 2)
                    localGroup.unknownXML = remoteLocationWins ? stale : reference
                    remoteGroup.unknownXML = remoteLocationWins ? reference : stale
                    localGroup.unknownXML.append(xml: "<CustomData><Item>local</Item></CustomData>", insertionIndex: 3)
                    remoteGroup.unknownXML.append(xml: "<CustomData><Item>remote</Item></CustomData>", insertionIndex: 3)
                    try XCTUnwrap(findGroup(remoteLocationWins ? workID : personalID, in: local.rootGroup)).groups.append(localGroup)
                    try XCTUnwrap(findGroup(remoteLocationWins ? personalID : workID, in: remote.rootGroup)).groups.append(remoteGroup)

                    let merged = try mergedResult(local: local, remote: remote)
                    let group = try XCTUnwrap(findGroup(personalID, in: merged.rootGroup)?.groups.first)
                    XCTAssertEqual(group.name, remoteContentWins ? "Remote" : "Local")
                    XCTAssertEqual(group.locationChanged, time(30))
                    XCTAssertEqual(group.entries.map(\.id), [alphaID])
                    XCTAssertEqual(group.unknownXML.nodes.filter { $0.elementName == "PreviousParentGroup" }, reference.nodes)
                    XCTAssertEqual(group.unknownXML.nodes.filter { $0.elementName == "CustomData" }.map(\.xml),
                                   ["<CustomData><Item>\(remoteContentWins ? "remote" : "local")</Item></CustomData>"])
                    let second = try mergedResult(local: .init(rootGroup: merged.rootGroup, meta: merged.meta), remote: remote)
                    XCTAssertFalse(second.summary.hasChanges)
                    XCTAssertEqual(findGroup(childID, in: second.rootGroup)?.unknownXML, group.unknownXML)
                }
            }
        }
    }

    func test_merge_recoveryReferenceAloneDoesNotCreateEntryHistory() throws {
        var localEntry = try makeEntry(id: alphaID, title: "Alpha", modified: time(20), locationChanged: time(5))
        var remoteEntry = localEntry
        localEntry.unknownXML = PreviousParentGroupXML.setting(personalID, in: .empty, newInsertionIndex: 2)
        remoteEntry.unknownXML = PreviousParentGroupXML.setting(workID, in: .empty, newInsertionIndex: 2)
        remoteEntry.locationChanged = time(30)
        remoteEntry.lastModificationTime = time(10)
        let merged = try mergedResult(local: makeSide(work: [localEntry]), remote: makeSide(work: [], personal: [remoteEntry]))
        let entry = try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup))
        XCTAssertEqual(PreviousParentGroupXML.parentID(in: entry.unknownXML), workID)
        XCTAssertTrue(entry.history.isEmpty)
        XCTAssertEqual(merged.summary.historyItemsAdded, 0)
    }

    func test_merge_recoveryReferenceChangeInSameParentIsReported() throws {
        let childID = UUID()
        let local = try makeSide(work: [makeEntry(id: alphaID, title: "Alpha", modified: time(10), locationChanged: time(5))])
        let remote = try makeSide(work: [makeEntry(id: alphaID, title: "Alpha", modified: time(10), locationChanged: time(30))])
        let localWork = try XCTUnwrap(findGroup(workID, in: local.rootGroup))
        let remoteWork = try XCTUnwrap(findGroup(workID, in: remote.rootGroup))
        localWork.groups.append(KPGroup(id: childID, name: "Child", lastModificationTime: time(10), locationChanged: time(5)))
        let remoteGroup = KPGroup(id: childID, name: "Child", lastModificationTime: time(10), locationChanged: time(30))
        remoteGroup.unknownXML = PreviousParentGroupXML.setting(personalID, in: .empty, newInsertionIndex: 2)
        remoteWork.groups.append(remoteGroup)
        remoteWork.entries[0].unknownXML = PreviousParentGroupXML.setting(personalID, in: .empty, newInsertionIndex: 2)

        let merged = try mergedResult(local: local, remote: remote)
        XCTAssertEqual(PreviousParentGroupXML.parentID(in: try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup)).unknownXML), personalID)
        XCTAssertEqual(PreviousParentGroupXML.parentID(in: try XCTUnwrap(findGroup(childID, in: merged.rootGroup)).unknownXML), personalID)
        XCTAssertEqual(merged.summary.entriesUpdated, 1)
        XCTAssertEqual(merged.summary.groupsUpdated, 1)
        XCTAssertTrue(merged.summary.hasChanges)
    }

    func test_merge_equalOrMissingLocationsKeepLocalRecoveryReference() throws {
        let childID = UUID()
        for location in [nil, time(30)] {
            var localEntry = try makeEntry(id: alphaID, title: "Local", modified: time(10), locationChanged: location)
            var remoteEntry = try makeEntry(id: alphaID, title: "Remote", modified: time(20), locationChanged: location)
            localEntry.unknownXML = PreviousParentGroupXML.setting(personalID, in: .empty, newInsertionIndex: 2)
            remoteEntry.unknownXML = PreviousParentGroupXML.setting(workID, in: .empty, newInsertionIndex: 2)
            let local = try makeSide(work: [localEntry])
            let remote = try makeSide(work: [remoteEntry])
            let localGroup = KPGroup(id: childID, name: "Local", lastModificationTime: time(10), locationChanged: location,
                                     unknownXML: localEntry.unknownXML)
            let remoteGroup = KPGroup(id: childID, name: "Remote", lastModificationTime: time(20), locationChanged: nil,
                                      unknownXML: remoteEntry.unknownXML)
            try XCTUnwrap(findGroup(workID, in: local.rootGroup)).groups.append(localGroup)
            try XCTUnwrap(findGroup(workID, in: remote.rootGroup)).groups.append(remoteGroup)

            let merged = try mergedResult(local: local, remote: remote)
            let entry = try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup))
            let group = try XCTUnwrap(findGroup(childID, in: merged.rootGroup))
            XCTAssertEqual(entry.title, "Remote")
            XCTAssertEqual(group.name, "Remote")
            XCTAssertEqual(PreviousParentGroupXML.parentID(in: entry.unknownXML), personalID)
            XCTAssertEqual(PreviousParentGroupXML.parentID(in: group.unknownXML), personalID)
        }
    }

    func test_merge_adoptsRemoteRecycleBinAndTheMoveIntoIt() throws {
        let binID = UUID()
        let local = try makeSide(work: [makeEntry(id: alphaID, title: "Alpha", modified: time(10))])
        let remoteRoot = try makeTree(work: [], extraGroups: [
            KPGroup(
                id: binID,
                name: "Recycle Bin",
                iconID: 43,
                entries: [
                    try makeEntry(id: alphaID, title: "Alpha", modified: time(10), locationChanged: time(20))
                ],
                creationTime: time(20),
                lastModificationTime: time(20),
                locationChanged: time(20)
            )
        ])
        var remoteMeta = KPMeta()
        remoteMeta.recycleBinUUID = binID
        remoteMeta.hasRecycleBinUUIDElement = true

        let merged = try mergedResult(
            local: local,
            remote: KDBXMerger.Side(rootGroup: remoteRoot, meta: remoteMeta)
        )

        XCTAssertEqual(merged.meta.recycleBinUUID, binID)
        XCTAssertTrue(merged.meta.hasRecycleBinUUIDElement)
        XCTAssertEqual(merged.rootGroup.recycleBinUUID, binID)
        let bin = try XCTUnwrap(findGroup(binID, in: merged.rootGroup))
        XCTAssertEqual(bin.entries.map(\.id), [alphaID])
    }

    func test_merge_keepsLocalRecycleBinUUIDWhenBothSidesHaveOne() throws {
        let localBinID = UUID()
        var localMeta = KPMeta()
        localMeta.recycleBinUUID = localBinID
        localMeta.hasRecycleBinUUIDElement = true
        var remoteMeta = KPMeta()
        remoteMeta.recycleBinUUID = UUID()
        remoteMeta.hasRecycleBinUUIDElement = true

        let merged = try mergedResult(
            local: KDBXMerger.Side(rootGroup: try makeTree(work: []), meta: localMeta),
            remote: KDBXMerger.Side(rootGroup: try makeTree(work: []), meta: remoteMeta)
        )

        XCTAssertEqual(merged.meta.recycleBinUUID, localBinID)
    }

    // MARK: - Custom icons

    func testMergeDoesNotResurrectDeletedIconAndPreservesImportedIconName() throws {
        let uuid = UUID()
        var entry = try makeEntry(id: betaID, title: "Remote", modified: time(20))
        entry.customIconUUID = uuid
        entry.history = [entry]
        let remoteRoot = try makeTree(work: [entry])
        var remoteMeta = KPMeta(customIcons: [uuid: Data([1])], customIconNames: [uuid: "Remote Name"])
        remoteMeta.unknownXML = try XCTUnwrap(CustomIconXML.adding(uuid: uuid, imageData: Data([1]), to: .empty))
        remoteMeta.unknownXML = try XCTUnwrap(CustomIconXML.renaming(uuid: uuid, to: "Remote Name", at: time(20), in: remoteMeta.unknownXML))
        let remote = KDBXMerger.Side(rootGroup: remoteRoot, meta: remoteMeta)
        let localRoot = try makeTree(work: [])
        let imported = try mergedResult(local: .init(rootGroup: localRoot, meta: KPMeta()), remote: remote)
        XCTAssertEqual(imported.meta.customIconNames[uuid], "Remote Name")
        XCTAssertTrue(imported.meta.unknownXML.nodes.contains { $0.xml.contains("<Name>Remote Name</Name>") })
        let meta = KPMeta(deletedObjects: [.init(uuid: uuid, deletionTime: time(30))])
        let deleted = try mergedResult(local: .init(rootGroup: localRoot, meta: meta), remote: remote)
        XCTAssertNil(deleted.meta.customIcons[uuid])
        let merged = try XCTUnwrap(deleted.rootGroup.allEntries.first { $0.id == betaID })
        XCTAssertNil(merged.customIconUUID)
        XCTAssertNil(merged.history.first?.customIconUUID)
        XCTAssertEqual(merged.title, "Remote")
        XCTAssertEqual(remoteRoot.allEntries[0].customIconUUID, uuid)
    }

    func testMergeTakesTheNewerRenameOfAnIconBothSidesHold() throws {
        let uuid = UUID()
        let base = try XCTUnwrap(CustomIconXML.adding(uuid: uuid, imageData: Data([1]), to: .empty))
        func side(name: String?, at date: Date) throws -> KDBXMerger.Side {
            var meta = KPMeta(customIcons: [uuid: Data([1])])
            meta.unknownXML = base
            if let name {
                meta.unknownXML = try XCTUnwrap(CustomIconXML.renaming(uuid: uuid, to: name, at: date, in: base))
                meta.customIconNames[uuid] = name
            }
            return KDBXMerger.Side(rootGroup: try makeTree(work: []), meta: meta)
        }

        let remote = try side(name: "Remote", at: time(20))
        let renamed = try mergedResult(local: try side(name: "Local", at: time(10)), remote: remote)
        XCTAssertEqual(renamed.meta.customIconNames[uuid], "Remote")
        XCTAssertEqual(renamed.summary.customIconsUpdated, 1)
        XCTAssertEqual(CustomIconXML.modificationTime(of: uuid, in: renamed.meta.unknownXML), time(20))
        XCTAssertFalse(renamed.meta.unknownXML.nodes.contains { $0.xml.contains("<Name>Local</Name>") })
        let again = try mergedResult(local: .init(rootGroup: renamed.rootGroup, meta: renamed.meta), remote: remote)
        XCTAssertFalse(again.summary.hasChanges)

        let unnamed = try mergedResult(local: try side(name: nil, at: time(0)), remote: remote)
        XCTAssertEqual(unnamed.meta.customIconNames[uuid], "Remote")

        let newerLocal = try mergedResult(local: try side(name: "Local", at: time(30)), remote: remote)
        XCTAssertEqual(newerLocal.meta.customIconNames[uuid], "Local")
        XCTAssertFalse(newerLocal.summary.hasChanges)
    }

    /// KeePass's `MergeInCustomIcons`: an icon renamed after another copy
    /// deleted it survives, and the obsolete tombstone is dropped.
    func testMergeKeepsAnIconRenamedAfterItsDeletion() throws {
        let uuid = UUID()
        var entry = try makeEntry(id: betaID, title: "Remote", modified: time(40))
        entry.customIconUUID = uuid
        var renamedMeta = KPMeta(customIcons: [uuid: Data([1])], customIconNames: [uuid: "Renamed"])
        renamedMeta.unknownXML = try XCTUnwrap(CustomIconXML.adding(uuid: uuid, imageData: Data([1]), to: .empty))
        renamedMeta.unknownXML = try XCTUnwrap(
            CustomIconXML.renaming(uuid: uuid, to: "Renamed", at: time(40), in: renamedMeta.unknownXML)
        )
        let renamed = KDBXMerger.Side(rootGroup: try makeTree(work: [entry]), meta: renamedMeta)
        let deleted = KDBXMerger.Side(
            rootGroup: try makeTree(work: []),
            meta: KPMeta(deletedObjects: [.init(uuid: uuid, deletionTime: time(30))])
        )

        for (local, remote) in [(deleted, renamed), (renamed, deleted)] {
            let merged = try mergedResult(local: local, remote: remote)
            XCTAssertEqual(merged.meta.customIcons[uuid], Data([1]))
            XCTAssertEqual(merged.meta.customIconNames[uuid], "Renamed")
            XCTAssertFalse(merged.meta.deletedObjects.contains { $0.uuid == uuid })
            XCTAssertEqual(merged.rootGroup.allEntries.first { $0.id == betaID }?.customIconUUID, uuid)
        }

        var olderRename = renamedMeta
        olderRename.unknownXML = try XCTUnwrap(
            CustomIconXML.renaming(uuid: uuid, to: "Renamed", at: time(20), in: renamedMeta.unknownXML)
        )
        let stillDeleted = try mergedResult(
            local: deleted,
            remote: .init(rootGroup: try makeTree(work: []), meta: olderRename)
        )
        XCTAssertNil(stillDeleted.meta.customIcons[uuid])
        XCTAssertTrue(stillDeleted.meta.deletedObjects.contains { $0.uuid == uuid })
    }

    func testDeletedIconDoesNotCreateHistoryWhenMergingTheSameRemoteAgain() throws {
        let uuid = UUID()
        var entry = try makeEntry(id: betaID, title: "Remote", modified: time(20))
        entry.customIconUUID = uuid
        entry.unknownXML.append(xml: "<CustomIconUUID>\(uuid.kdbxBase64String)</CustomIconUUID>", insertionIndex: 2)
        var remoteMeta = KPMeta(customIcons: [uuid: Data([1])])
        remoteMeta.unknownXML = try XCTUnwrap(CustomIconXML.adding(uuid: uuid, imageData: Data([1]), to: .empty))
        let remote = KDBXMerger.Side(rootGroup: try makeTree(work: [entry]), meta: remoteMeta)
        let local = KDBXMerger.Side(rootGroup: try makeTree(work: []),
                                   meta: KPMeta(deletedObjects: [.init(uuid: uuid, deletionTime: time(30))]))
        let first = try mergedResult(local: local, remote: remote)
        let second = try mergedResult(local: .init(rootGroup: first.rootGroup, meta: first.meta), remote: remote)
        XCTAssertFalse(second.summary.hasChanges)
        let merged = try XCTUnwrap(second.rootGroup.allEntries.first { $0.id == betaID })
        XCTAssertNil(merged.customIconUUID)
        XCTAssertTrue(merged.history.isEmpty)
        XCTAssertEqual(remote.rootGroup.allEntries[0].customIconUUID, uuid)
    }

    func test_merge_splicesRemoteOnlyCustomIconForANewEntry() throws {
        let iconID = UUID()
        let iconData = Data([0x89, 0x50, 0x4E, 0x47])
        var remoteBeta = try makeEntry(id: betaID, title: "Beta", modified: time(20))
        remoteBeta.customIconUUID = iconID
        var remoteMeta = KPMeta()
        remoteMeta.customIcons = [iconID: iconData]
        remoteMeta.unknownXML = try XCTUnwrap(CustomIconXML.adding(uuid: iconID, imageData: iconData, to: .empty))

        let merged = try mergedResult(
            local: try makeSide(work: [makeEntry(id: alphaID, title: "Alpha", modified: time(10))]),
            remote: KDBXMerger.Side(
                rootGroup: try makeTree(work: [
                    try makeEntry(id: alphaID, title: "Alpha", modified: time(10)),
                    remoteBeta,
                ]),
                meta: remoteMeta
            )
        )

        XCTAssertEqual(merged.meta.customIcons[iconID], iconData)
        XCTAssertEqual(merged.summary.customIconsSpliced, 1)
        XCTAssertEqual(merged.summary.danglingIconReferences, 0)
        let spliced = merged.meta.unknownXML.nodes.first { $0.elementName == "CustomIcons" }
        XCTAssertNotNil(spliced)
        XCTAssertTrue(try XCTUnwrap(spliced).xml.contains(iconData.base64EncodedString()))
    }

    func test_merge_keepsDanglingIconReferenceWhenRemoteHasNoImage() throws {
        let iconID = UUID()
        var remoteBeta = try makeEntry(id: betaID, title: "Beta", modified: time(20))
        remoteBeta.customIconUUID = iconID

        let merged = try mergedResult(
            local: try makeSide(work: [makeEntry(id: alphaID, title: "Alpha", modified: time(10))]),
            remote: try makeSide(work: [
                makeEntry(id: alphaID, title: "Alpha", modified: time(10)),
                remoteBeta,
            ])
        )

        let beta = try XCTUnwrap(findEntry(betaID, in: merged.rootGroup))
        XCTAssertEqual(beta.customIconUUID, iconID)
        XCTAssertNil(merged.meta.customIcons[iconID])
        XCTAssertEqual(merged.summary.customIconsSpliced, 0)
        XCTAssertEqual(merged.summary.danglingIconReferences, 1)
    }

    func test_merge_keepsDanglingIconReferenceWhenTheFragmentCannotBeSpliced() throws {
        let iconID = UUID()
        var localMeta = KPMeta()
        // A `<CustomIcons/>` that never reached the parser has no closing tag to
        // splice before, which is exactly the shape `CustomIconXML` refuses.
        localMeta.unknownXML = OpaqueXMLNodes(nodes: [.init(insertionIndex: 0, xml: "<CustomIcons/>")])
        var remoteBeta = try makeEntry(id: betaID, title: "Beta", modified: time(20))
        remoteBeta.customIconUUID = iconID
        var remoteMeta = KPMeta()
        remoteMeta.customIcons = [iconID: Data([0x01, 0x02])]

        let merged = try mergedResult(
            local: KDBXMerger.Side(
                rootGroup: try makeTree(work: [makeEntry(id: alphaID, title: "Alpha", modified: time(10))]),
                meta: localMeta
            ),
            remote: KDBXMerger.Side(
                rootGroup: try makeTree(work: [
                    try makeEntry(id: alphaID, title: "Alpha", modified: time(10)),
                    remoteBeta,
                ]),
                meta: remoteMeta
            )
        )

        XCTAssertEqual(merged.meta.unknownXML, localMeta.unknownXML)
        XCTAssertEqual(merged.summary.customIconsSpliced, 0)
        XCTAssertEqual(merged.summary.danglingIconReferences, 1)
    }

    // MARK: - Blockers

    func test_merge_declinesWhenBinaryPoolsDivergeAndAttachmentsAreReferenced() throws {
        var localAlpha = try makeEntry(id: alphaID, title: "Alpha", modified: time(10))
        localAlpha.attachments = [KPAttachment(name: "note.txt", ref: 0)]
        let local = KDBXMerger.Side(
            rootGroup: try makeTree(work: [localAlpha]),
            meta: KPMeta(),
            binaryPoolFields: [Data([0x00, 0x41])]
        )
        let remote = KDBXMerger.Side(
            rootGroup: try makeTree(work: [localAlpha]),
            meta: KPMeta(),
            binaryPoolFields: [Data([0x00, 0x42])]
        )

        let outcome = try KDBXMerger.merge(local: local, remote: remote, sessionKey: sessionKey)

        guard case .declined(let blockers) = outcome else {
            return XCTFail("Expected a decline, got \(outcome)")
        }
        XCTAssertEqual(blockers, [.attachmentPoolDivergence])
    }

    func test_merge_declinesWhenOnlyAHistoryVersionReferencesAnAttachment() throws {
        var historic = try makeEntry(id: alphaID, title: "Alpha v1", modified: time(5))
        historic.attachments = [KPAttachment(name: "note.txt", ref: 0)]
        var localAlpha = try makeEntry(id: alphaID, title: "Alpha", modified: time(10))
        localAlpha.history = [historic]

        let outcome = try KDBXMerger.merge(
            local: KDBXMerger.Side(
                rootGroup: try makeTree(work: [localAlpha]),
                meta: KPMeta(),
                binaryPoolFields: [Data([0x00, 0x41])]
            ),
            remote: KDBXMerger.Side(
                rootGroup: try makeTree(work: [localAlpha]),
                meta: KPMeta(),
                binaryPoolFields: []
            ),
            sessionKey: sessionKey
        )

        guard case .declined(let blockers) = outcome else {
            return XCTFail("Expected a decline, got \(outcome)")
        }
        XCTAssertEqual(blockers, [.attachmentPoolDivergence])
    }

    func test_merge_divergentPoolsAreNotABlockerWithoutAttachmentReferences() throws {
        let local = KDBXMerger.Side(
            rootGroup: try makeTree(work: [makeEntry(id: alphaID, title: "Alpha", modified: time(10))]),
            meta: KPMeta(),
            binaryPoolFields: [Data([0x00, 0x41])]
        )
        let remote = KDBXMerger.Side(
            rootGroup: try makeTree(work: [makeEntry(id: alphaID, title: "Remote Alpha", modified: time(20))]),
            meta: KPMeta(),
            binaryPoolFields: [Data([0x00, 0x42]), Data([0x00, 0x43])]
        )

        let merged = try mergedResult(local: local, remote: remote)

        XCTAssertEqual(try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup)).title, "Remote Alpha")
    }

    func test_merge_declinesWhenARemoteRefPointsIntoThePoolLocalAppended() throws {
        // Local appended a file at index 0 in an unsaved edit; the remote,
        // with the pool the session opened, carries a dangling ref 0.
        var localAlpha = try makeEntry(id: alphaID, title: "Alpha", modified: time(10))
        localAlpha.attachments = [KPAttachment(name: "local.txt", ref: 0)]
        var remoteBeta = try makeEntry(id: betaID, title: "Beta", modified: time(10))
        remoteBeta.attachments = [KPAttachment(name: "missing.txt", ref: 0)]

        let outcome = try KDBXMerger.merge(
            local: KDBXMerger.Side(rootGroup: try makeTree(work: [localAlpha]), meta: KPMeta(), binaryPoolFields: [Data([0x01, 0x41])]),
            remote: KDBXMerger.Side(rootGroup: try makeTree(work: [remoteBeta]), meta: KPMeta(), binaryPoolFields: []),
            sessionKey: sessionKey
        )

        guard case .declined(let blockers) = outcome else {
            return XCTFail("Expected a decline, got \(outcome)")
        }
        XCTAssertEqual(blockers, [.attachmentPoolDivergence])
    }

    func test_merge_acceptsARemotePoolTheLocalPoolOnlyExtends() throws {
        var localAlpha = try makeEntry(id: alphaID, title: "Alpha", modified: time(10))
        localAlpha.attachments = [KPAttachment(name: "added.txt", ref: 1)]
        var remoteBeta = try makeEntry(id: betaID, title: "Beta", modified: time(10))
        remoteBeta.attachments = [
            KPAttachment(name: "shared.txt", ref: 0),
            // Past the local pool too, so it stays dangling after the merge.
            KPAttachment(name: "missing.txt", ref: 5),
        ]

        let merged = try mergedResult(
            local: KDBXMerger.Side(
                rootGroup: try makeTree(work: [localAlpha]),
                meta: KPMeta(),
                binaryPoolFields: [Data([0x00, 0x41]), Data([0x01, 0x42])]
            ),
            remote: KDBXMerger.Side(
                rootGroup: try makeTree(work: [remoteBeta]),
                meta: KPMeta(),
                binaryPoolFields: [Data([0x00, 0x41])]
            )
        )

        XCTAssertEqual(try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup)).attachments, localAlpha.attachments)
        XCTAssertEqual(try XCTUnwrap(findEntry(betaID, in: merged.rootGroup)).attachments, remoteBeta.attachments)
    }

    func test_merge_identicalPoolsWithAttachmentsAreNotABlocker() throws {
        var localAlpha = try makeEntry(id: alphaID, title: "Alpha", modified: time(10))
        localAlpha.attachments = [KPAttachment(name: "note.txt", ref: 0)]
        let pool = [Data([0x00, 0x41])]

        let merged = try mergedResult(
            local: KDBXMerger.Side(rootGroup: try makeTree(work: [localAlpha]), meta: KPMeta(), binaryPoolFields: pool),
            remote: KDBXMerger.Side(rootGroup: try makeTree(work: [localAlpha]), meta: KPMeta(), binaryPoolFields: pool)
        )

        XCTAssertEqual(try XCTUnwrap(findEntry(alphaID, in: merged.rootGroup)).attachments, localAlpha.attachments)
    }

    // MARK: - Idempotence and isolation

    func test_merge_isIdempotent() throws {
        let scenario = try makeRichScenario()

        let first = try mergedResult(local: scenario.local, remote: scenario.remote)
        XCTAssertTrue(first.summary.hasChanges)

        let second = try mergedResult(
            local: KDBXMerger.Side(rootGroup: first.rootGroup, meta: first.meta),
            remote: scenario.remote
        )

        XCTAssertFalse(second.summary.hasChanges)
        XCTAssertEqual(snapshot(of: second.rootGroup), snapshot(of: first.rootGroup))
        XCTAssertEqual(second.meta.deletedObjects, first.meta.deletedObjects)
        XCTAssertEqual(second.meta.customIcons, first.meta.customIcons)
        XCTAssertEqual(second.meta.unknownXML, first.meta.unknownXML)
    }

    func test_merge_isIdempotentAfterAResurrection() throws {
        var localMeta = KPMeta()
        localMeta.deletedObjects = [KPDeletedObject(uuid: alphaID, deletionTime: time(20))]
        let local = KDBXMerger.Side(rootGroup: try makeTree(work: []), meta: localMeta)
        let remote = try makeSide(work: [makeEntry(id: alphaID, title: "Edited After Delete", modified: time(30))])

        let first = try mergedResult(local: local, remote: remote)
        let second = try mergedResult(
            local: KDBXMerger.Side(rootGroup: first.rootGroup, meta: first.meta),
            remote: remote
        )

        XCTAssertFalse(second.summary.hasChanges)
        XCTAssertEqual(snapshot(of: second.rootGroup), snapshot(of: first.rootGroup))
        XCTAssertTrue(second.meta.deletedObjects.isEmpty)
    }

    func test_merge_resultAliasesNeitherInput() throws {
        let scenario = try makeRichScenario()
        let localBefore = snapshot(of: scenario.local.rootGroup)
        let remoteBefore = snapshot(of: scenario.remote.rootGroup)

        let merged = try mergedResult(local: scenario.local, remote: scenario.remote)

        func mutateEverything(_ group: KPGroup) {
            group.name += " (mutated)"
            group.lastModificationTime = time(9_999)
            for index in group.entries.indices {
                group.entries[index].title += " (mutated)"
            }
            group.entries.append(try! makeEntry(id: UUID(), title: "Injected", modified: time(9_999)))
            for child in group.groups { mutateEverything(child) }
        }
        mutateEverything(merged.rootGroup)

        XCTAssertEqual(snapshot(of: scenario.local.rootGroup), localBefore)
        XCTAssertEqual(snapshot(of: scenario.remote.rootGroup), remoteBefore)
    }

    // MARK: - Helpers

    private func mergedResult(
        local: KDBXMerger.Side,
        remote: KDBXMerger.Side,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> KDBXMerger.Merged {
        let outcome = try KDBXMerger.merge(local: local, remote: remote, sessionKey: sessionKey)
        switch outcome {
        case .merged(let merged): return merged
        case .declined(let blockers):
            XCTFail("Unexpected decline: \(blockers)", file: file, line: line)
            throw MergeTestError.unexpectedDecline
        }
    }

    private enum MergeTestError: Error {
        case unexpectedDecline
    }

    private func time(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    private func makeEntry(
        id: UUID,
        title: String,
        modified: Date?,
        locationChanged: Date? = nil
    ) throws -> KPEntry {
        KPEntry(
            id: id,
            title: title,
            username: "user",
            password: try EncryptedValue.encrypt("password", using: sessionKey),
            url: "https://example.com",
            creationTime: time(0),
            lastModificationTime: modified,
            locationChanged: locationChanged
        )
    }

    private func makeTree(
        work: [KPEntry],
        personal: [KPEntry] = [],
        extraGroups: [KPGroup] = []
    ) throws -> KPGroup {
        KPGroup(
            id: rootID,
            name: "Root",
            groups: [
                KPGroup(
                    id: workID,
                    name: "Work",
                    entries: work,
                    creationTime: time(0),
                    lastModificationTime: time(0),
                    locationChanged: time(0)
                ),
                KPGroup(
                    id: personalID,
                    name: "Personal",
                    entries: personal,
                    creationTime: time(0),
                    lastModificationTime: time(0),
                    locationChanged: time(0)
                ),
            ] + extraGroups,
            creationTime: time(0),
            lastModificationTime: time(0)
        )
    }

    private func makeSide(work: [KPEntry], personal: [KPEntry] = []) throws -> KDBXMerger.Side {
        KDBXMerger.Side(rootGroup: try makeTree(work: work, personal: personal), meta: KPMeta())
    }

    /// A scenario touching every merge effect at once: an added entry, an added
    /// group, a remote-won conflict, a local-won conflict, a move, a history
    /// union, a deletion, and a spliced icon.
    private func makeRichScenario() throws -> (local: KDBXMerger.Side, remote: KDBXMerger.Side) {
        let addedGroupID = UUID()
        let gammaID = UUID()
        let ghostID = UUID()
        let iconID = UUID()

        var localAlpha = try makeEntry(id: alphaID, title: "Local Alpha", modified: time(10), locationChanged: time(1))
        localAlpha.history = [try makeEntry(id: alphaID, title: "Alpha v0", modified: time(2))]
        let localBeta = try makeEntry(id: betaID, title: "Local Beta", modified: time(40), locationChanged: time(1))
        let localGhost = try makeEntry(id: ghostID, title: "Ghost", modified: time(5))

        let localRoot = try makeTree(work: [localAlpha, localBeta], personal: [localGhost])
        let local = KDBXMerger.Side(rootGroup: localRoot, meta: KPMeta())

        var remoteAlpha = try makeEntry(id: alphaID, title: "Remote Alpha", modified: time(30), locationChanged: time(25))
        remoteAlpha.history = [try makeEntry(id: alphaID, title: "Alpha v1", modified: time(3))]
        let remoteBeta = try makeEntry(id: betaID, title: "Remote Beta", modified: time(20), locationChanged: time(1))
        var remoteGamma = try makeEntry(id: gammaID, title: "Gamma", modified: time(35))
        remoteGamma.customIconUUID = iconID

        let remoteRoot = try makeTree(
            work: [remoteBeta],
            personal: [remoteAlpha],
            extraGroups: [
                KPGroup(
                    id: addedGroupID,
                    name: "Remote Only",
                    entries: [remoteGamma],
                    creationTime: time(35),
                    lastModificationTime: time(35),
                    locationChanged: time(35)
                )
            ]
        )
        var remoteMeta = KPMeta()
        remoteMeta.customIcons = [iconID: Data([0x89, 0x50, 0x4E, 0x47])]
        remoteMeta.unknownXML = try XCTUnwrap(CustomIconXML.adding(uuid: iconID, imageData: remoteMeta.customIcons[iconID]!, to: .empty))
        remoteMeta.deletedObjects = [KPDeletedObject(uuid: ghostID, deletionTime: time(50))]

        return (local, KDBXMerger.Side(rootGroup: remoteRoot, meta: remoteMeta))
    }

    private func findGroup(_ id: UUID, in group: KPGroup) -> KPGroup? {
        if group.id == id { return group }
        for child in group.groups {
            if let found = findGroup(id, in: child) { return found }
        }
        return nil
    }

    private func findEntry(_ id: UUID, in group: KPGroup) -> KPEntry? {
        if let entry = group.entries.first(where: { $0.id == id }) { return entry }
        for child in group.groups {
            if let found = findEntry(id, in: child) { return found }
        }
        return nil
    }

    /// A deterministic, order-preserving description of a tree, so equality
    /// failures read as a diff instead of a boolean.
    private func snapshot(of group: KPGroup, indent: String = "") -> String {
        var lines = [
            "\(indent)group \(group.id) \(group.name) icon=\(group.iconID) "
                + "mod=\(stamp(group.lastModificationTime)) loc=\(stamp(group.locationChanged))"
        ]
        for entry in group.entries {
            lines.append(
                "\(indent)  entry \(entry.id) \(entry.title) mod=\(stamp(entry.lastModificationTime)) "
                    + "loc=\(stamp(entry.locationChanged)) icon=\(entry.customIconUUID?.uuidString ?? "-") "
                    + "history=[\(entry.history.map { "\($0.title)@\(stamp($0.lastModificationTime))" }.joined(separator: ","))]"
            )
        }
        for child in group.groups {
            lines.append(snapshot(of: child, indent: indent + "  "))
        }
        return lines.joined(separator: "\n")
    }

    private func stamp(_ date: Date?) -> String {
        date.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
    }
}
