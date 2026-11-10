import XCTest
import KDBXXML
@testable import KeeForge

final class ModelLogicTests: XCTestCase {
    func testKPGroupAllEntriesFlattensRecursively() {
        let entry1 = KPEntry(title: "one")
        let entry2 = KPEntry(title: "two")
        let entry3 = KPEntry(title: "three")

        let deepGroup = KPGroup(name: "deep", entries: [entry3])
        let childGroup = KPGroup(name: "child", entries: [entry2], groups: [deepGroup])
        let root = KPGroup(name: "root", entries: [entry1], groups: [childGroup])

        let titles = root.allEntries.map(\.title)

        XCTAssertEqual(titles, ["one", "two", "three"])
    }

    func testKPEntrySystemIconNameMapsKnownAndDefaultIDs() {
        XCTAssertEqual(KPEntry(iconID: 0).systemIconName, "key.fill")
        XCTAssertEqual(KPEntry(iconID: 1).systemIconName, "globe")
        XCTAssertEqual(KPEntry(iconID: 19).systemIconName, "envelope.fill")
        XCTAssertEqual(KPEntry(iconID: 37).systemIconName, "building.columns.fill")
        XCTAssertEqual(KPEntry(iconID: 66).systemIconName, "banknote.fill")
        XCTAssertEqual(KPEntry(iconID: 68).systemIconName, "iphone")
        XCTAssertEqual(KPEntry(iconID: 999).systemIconName, "key.fill")
        XCTAssertEqual(KPEntry(iconID: -1).systemIconName, "key.fill")
    }

    func testStandardIconTableCoversAllKDBXStandardIcons() {
        // KDBX 4.x defines standard icons 0 through 68; every one must map to
        // a concrete symbol rather than falling through to the default.
        for iconID in 0...68 {
            XCTAssertNotNil(
                KPEntry.standardIconNames[iconID],
                "Missing SF Symbol mapping for standard icon \(iconID)"
            )
        }
    }

    @MainActor
    func testStandardIconPalettesCoverAllKDBXStandardIcons() {
        let palettes = StandardIconView.palettes
        let keyPalette = StandardIconView.palette(for: 0)
        let warningPalette = StandardIconView.palette(for: 2)
        let checkedPalette = StandardIconView.palette(for: 53)
        let fallbackPalette = StandardIconView.palette(for: 999, fallback: .blue)

        XCTAssertEqual(Set(palettes.keys), Set(0...68))
        XCTAssertGreaterThan(Set(palettes.values).count, 1)
        XCTAssertEqual(keyPalette, .gold)
        XCTAssertEqual(warningPalette, .red)
        XCTAssertEqual(checkedPalette, .green)
        XCTAssertEqual(fallbackPalette, .blue)
    }

    func testKPEntryIsExpiredRequiresEnabledPastExpiryTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let past = now.addingTimeInterval(-1)

        XCTAssertTrue(
            KPEntry(expires: true, expiryTime: past).isExpired(at: now)
        )
        XCTAssertFalse(
            KPEntry(expires: true, expiryTime: now.addingTimeInterval(1)).isExpired(at: now)
        )
        XCTAssertFalse(
            KPEntry(expires: false, expiryTime: past).isExpired(at: now)
        )
        XCTAssertFalse(KPEntry(expires: true, expiryTime: nil).isExpired(at: now))
        XCTAssertEqual(KPEntry(expires: true, expiryTime: past).enabledExpiryTime, past)
        XCTAssertNil(KPEntry(expires: false, expiryTime: past).enabledExpiryTime)
    }

    /// 2031-06-15T08:30:00Z is 64 074 875 400 s after 0001-01-01 UTC.
    func testKDBXDateEncodingIsLittleEndianWholeSecondsSinceYearOne() {
        let date = Date(timeIntervalSince1970: 1_939_278_600.75)
        var expectedSeconds = Int64(64_074_875_400).littleEndian
        let expected = withUnsafeBytes(of: &expectedSeconds) { Data($0).base64EncodedString() }

        XCTAssertEqual(date.kdbxBase64String, expected)
        XCTAssertEqual(date.kdbxStoredDate, Date(timeIntervalSince1970: 1_939_278_600))
        XCTAssertEqual(date.kdbxStoredDate.kdbxBase64String, expected)
    }

    func testKPGroupSystemIconNameMapsKnownAndDefaultIDs() {
        XCTAssertEqual(KPGroup(name: "a", iconID: 0).systemIconName, "key.fill")
        XCTAssertEqual(KPGroup(name: "a", iconID: 1).systemIconName, "globe")
        XCTAssertEqual(KPGroup(name: "a", iconID: 2).systemIconName, "exclamationmark.triangle.fill")
        XCTAssertEqual(KPGroup(name: "a", iconID: 3).systemIconName, "server.rack")
        XCTAssertEqual(KPGroup(name: "a", iconID: 43).systemIconName, "trash.fill")
        XCTAssertEqual(KPGroup(name: "a", iconID: 48).systemIconName, "folder.fill")
        XCTAssertEqual(KPGroup(name: "a", iconID: 49).systemIconName, "folder.fill")
        XCTAssertEqual(KPGroup(name: "a", iconID: 999).systemIconName, "folder.fill")
    }

    func testKPEntryHashableAndEqualityUseOnlyID() {
        let id = UUID()
        let lhs = KPEntry(id: id, title: "first")
        let rhs = KPEntry(id: id, title: "second")

        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(Set([lhs, rhs]).count, 1)
    }

    func testKPGroupHashableAndEqualityUseOnlyID() {
        let id = UUID()
        let lhs = KPGroup(id: id, name: "first")
        let rhs = KPGroup(id: id, name: "second", entries: [KPEntry(title: "x")])

        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(Set([lhs, rhs]).count, 1)
    }

    // MARK: - autoFillEntries / EnableSearching

    func testAutoFillEntriesIncludesEverythingByDefault() {
        let root = KPGroup(
            name: "Root",
            entries: [KPEntry(title: "top")],
            groups: [KPGroup(name: "Child", entries: [KPEntry(title: "nested")])]
        )

        XCTAssertEqual(titles(root.autoFillEntries()), ["top", "nested"])
    }

    func testAutoFillEntriesSkipsDisabledGroupAndItsSubgroups() {
        let root = KPGroup(
            name: "Root",
            entries: [KPEntry(title: "top")],
            groups: [
                KPGroup(
                    name: "Secret",
                    entries: [KPEntry(title: "hidden")],
                    groups: [KPGroup(name: "Deeper", entries: [KPEntry(title: "alsoHidden")])],
                    searchingEnabled: .disabled
                ),
                KPGroup(name: "Normal", entries: [KPEntry(title: "visible")]),
            ]
        )

        XCTAssertEqual(titles(root.autoFillEntries()), ["top", "visible"])
    }

    func testAutoFillEntriesTreatsInheritAndAbsentElementTheSame() {
        func makeRoot(child: KPInheritableBool?) -> KPGroup {
            KPGroup(
                name: "Root",
                groups: [
                    KPGroup(
                        name: "Secret",
                        groups: [
                            KPGroup(
                                name: "Child",
                                entries: [KPEntry(title: "nested")],
                                searchingEnabled: child
                            )
                        ],
                        searchingEnabled: .disabled
                    )
                ]
            )
        }

        XCTAssertEqual(titles(makeRoot(child: .inherit).autoFillEntries()), [])
        XCTAssertEqual(titles(makeRoot(child: nil).autoFillEntries()), [])
    }

    func testAutoFillEntriesLetsSubgroupOverrideDisabledParent() {
        let root = KPGroup(
            name: "Root",
            groups: [
                KPGroup(
                    name: "Secret",
                    entries: [KPEntry(title: "hidden")],
                    groups: [
                        KPGroup(
                            name: "Exception",
                            entries: [KPEntry(title: "visible")],
                            searchingEnabled: .enabled
                        )
                    ],
                    searchingEnabled: .disabled
                )
            ]
        )

        XCTAssertEqual(titles(root.autoFillEntries()), ["visible"])
    }

    func testAutoFillEntriesStillHonoursExcludedGroupID() {
        let recycleBinID = UUID()
        let root = KPGroup(
            name: "Root",
            entries: [KPEntry(title: "top")],
            groups: [
                KPGroup(id: recycleBinID, name: "Recycle Bin", entries: [KPEntry(title: "trashed")])
            ]
        )

        XCTAssertEqual(titles(root.autoFillEntries(excludingGroupID: recycleBinID)), ["top"])
    }

    func testAutoFillEntriesWithNilExclusionKeepsWholeTree() {
        let root = KPGroup(
            name: "Root",
            entries: [KPEntry(title: "top")],
            groups: [KPGroup(name: "Child", entries: [KPEntry(title: "nested")])]
        )

        XCTAssertEqual(titles(root.autoFillEntries(excludingGroupID: nil)), ["top", "nested"])
    }

    // MARK: - KeeOTPSource.rewriting

    // The query rules are pinned in the package's `KeeOTPQueryTests`; this
    // checks the forwarding keeps the field name and passes every setting.
    func testKeeOTPSourceRewritingForwardsToThePackageAndKeepsTheFieldName() {
        let source = KeeOTPSource(fieldName: "OTP", rawQuery: "key=OLD&step=30&size=6&otpHashMode=SHA1")

        XCTAssertEqual(
            source.rewriting(secret: "NEW", period: 45, digits: 8, algorithm: .sha512),
            KeeOTPSource(fieldName: "OTP", rawQuery: "key=NEW&step=45&size=8&otpHashMode=SHA512&encoding=Base32")
        )
        XCTAssertEqual(
            source.rewriting(period: 60, digits: 6, algorithm: .sha256).rawQuery,
            "key=OLD&step=60&size=6&otpHashMode=SHA256"
        )
    }

    private func titles(_ entries: [KPEntry]) -> [String] {
        entries.map(\.title)
    }
}
