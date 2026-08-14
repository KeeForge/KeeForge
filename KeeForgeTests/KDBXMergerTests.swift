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
        XCTAssertEqual(survived.meta.deletedObjects.map(\.uuid), [doomedID])
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

    func test_merge_splicesRemoteOnlyCustomIconForANewEntry() throws {
        let iconID = UUID()
        let iconData = Data([0x89, 0x50, 0x4E, 0x47])
        var remoteBeta = try makeEntry(id: betaID, title: "Beta", modified: time(20))
        remoteBeta.customIconUUID = iconID
        var remoteMeta = KPMeta()
        remoteMeta.customIcons = [iconID: iconData]

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
