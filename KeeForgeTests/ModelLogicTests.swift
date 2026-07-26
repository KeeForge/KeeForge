import XCTest
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

    func testInheritableBoolParsingIsCaseInsensitiveAndRejectsGarbage() {
        XCTAssertEqual(KPInheritableBool.parse("True"), .enabled)
        XCTAssertEqual(KPInheritableBool.parse("true"), .enabled)
        XCTAssertEqual(KPInheritableBool.parse("FALSE"), .disabled)
        XCTAssertEqual(KPInheritableBool.parse(" null \n"), .inherit)
        XCTAssertNil(KPInheritableBool.parse(""))
        XCTAssertNil(KPInheritableBool.parse("0"))
        XCTAssertNil(KPInheritableBool.parse("yes"))
    }

    // MARK: - OpaqueXMLNodes element-name handling

    func testOpaqueNodeElementNameReadsTheOutermostStartTag() {
        func name(_ xml: String) -> String? {
            OpaqueXMLNodes.Node(insertionIndex: 0, xml: xml).elementName
        }

        XCTAssertEqual(name("<EnableSearching>maybe</EnableSearching>"), "EnableSearching")
        XCTAssertEqual(name("<EnableSearching/>"), "EnableSearching")
        XCTAssertEqual(name("<EnableSearching />"), "EnableSearching")
        XCTAssertEqual(name("<Value Protected=\"True\">x</Value>"), "Value")
        XCTAssertNil(name("<!-- a comment -->"))
        XCTAssertNil(name("<?xml version=\"1.0\"?>"))
        XCTAssertNil(name("stray text"))
        XCTAssertNil(name(""))
    }

    func testRemoveDirectChildrenDropsOnlyMatchingTopLevelNodes() {
        var nodes = OpaqueXMLNodes()
        nodes.append(xml: "<Notes>keep</Notes>", insertionIndex: 1)
        nodes.append(xml: "<EnableSearching>maybe</EnableSearching>", insertionIndex: 1)
        nodes.append(xml: "<EnableSearchingExtra>keep</EnableSearchingExtra>", insertionIndex: 2)
        nodes.append(xml: "<EnableSearching>nested</EnableSearching>", path: ["Times"], insertionIndex: 0)

        nodes.removeDirectChildren(named: "EnableSearching")

        XCTAssertEqual(
            nodes.nodes.map(\.xml),
            [
                "<Notes>keep</Notes>",
                "<EnableSearchingExtra>keep</EnableSearchingExtra>",
                "<EnableSearching>nested</EnableSearching>",
            ],
            "Only direct children with an exact name match are dropped"
        )
        XCTAssertEqual(
            nodes.xmlFragments(insertionIndex: 1),
            ["<Notes>keep</Notes>"],
            "Surviving siblings keep their insertion index"
        )
    }

    // MARK: - KeeOTPSource.rewriting

    // `EntryEditViewModel` calls `rewriting` whenever an edit changes a KeeOTP
    // entry's secret or timing, then hands the result straight back to the
    // writer as the entry's `otp` field. Anything it drops or mangles is
    // written to disk, so the pass-through and append rules are pinned here.

    func testKeeOTPSourceRewritingReplacesKnownParametersInPlaceAndPreservesTheRest() {
        let source = KeeOTPSource(
            fieldName: "otp",
            rawQuery: "key=OLDSECRET&type=TOTP&step=30&size=6&encoding=UTF8&otpHashMode=SHA1&custom=keep%20me&bare"
        )

        let rewritten = source.rewriting(secret: "NEWSECRET", period: 45, digits: 8, algorithm: .sha512)

        XCTAssertEqual(rewritten.fieldName, "otp")
        XCTAssertEqual(
            rewritten.rawQuery,
            "key=NEWSECRET&type=TOTP&step=45&size=8&encoding=Base32&otpHashMode=SHA512&custom=keep%20me&bare",
            "Unrelated parameters, their order, and their percent-encoding must survive verbatim"
        )
    }

    func testKeeOTPSourceRewritingWithoutSecretLeavesKeyAndEncodingUntouched() {
        // `secret: nil` means "settings changed, secret did not": the stored
        // key and its declared encoding must not be rewritten to Base32.
        let source = KeeOTPSource(
            fieldName: "OTP",
            rawQuery: "key=OLDSECRET&type=TOTP&step=30&size=6&encoding=UTF8&otpHashMode=SHA1"
        )

        let rewritten = source.rewriting(period: 60, digits: 6, algorithm: .sha256)

        XCTAssertEqual(rewritten.fieldName, "OTP")
        XCTAssertEqual(
            rewritten.rawQuery,
            "key=OLDSECRET&type=TOTP&step=60&size=6&encoding=UTF8&otpHashMode=SHA256"
        )
    }

    func testKeeOTPSourceRewritingAppendsOmittedParametersUnderCanonicalNames() {
        // KeeOtp2 omits default-valued parameters, so "key=SECRET" is a
        // complete payload; changed settings have to be appended.
        let minimal = KeeOTPSource(fieldName: "otp", rawQuery: "key=JBSWY3DP")

        XCTAssertEqual(
            minimal.rewriting(period: 45, digits: 8, algorithm: .sha256).rawQuery,
            "key=JBSWY3DP&step=45&size=8&otpHashMode=SHA256",
            "With no new secret there is nothing to declare an encoding for"
        )
        XCTAssertEqual(
            minimal.rewriting(secret: "NEWSECRET", period: 45, digits: 8, algorithm: .sha256).rawQuery,
            "key=NEWSECRET&encoding=Base32&step=45&size=8&otpHashMode=SHA256",
            "A rewritten secret is always Base32, so the encoding must be stated"
        )
    }

    func testKeeOTPSourceRewritingMatchesNamesCaseInsensitivelyAndPercentDecoded() {
        let source = KeeOTPSource(fieldName: "otp", rawQuery: "KEY=OLD&%73tep=30&OTPHASHMODE=SHA1")

        let rewritten = source.rewriting(secret: "NEW", period: 45, digits: 8, algorithm: .sha512)

        XCTAssertEqual(
            rewritten.rawQuery,
            "KEY=NEW&%73tep=45&OTPHASHMODE=SHA512&encoding=Base32&size=8",
            "Names match case-insensitively after percent-decoding, but keep their original spelling"
        )
    }

    func testKeeOTPSourceRewritingRewritesOnlyTheFirstDuplicateParameter() {
        // The parser rejects duplicate `key` payloads, so a duplicate can only
        // reach here from a hand-edited field; leaving the later copy alone
        // keeps the rewrite from inventing a second authoritative value.
        let source = KeeOTPSource(fieldName: "otp", rawQuery: "step=30&step=99&key=OLD")

        let rewritten = source.rewriting(secret: "NEW", period: 45, digits: 8, algorithm: .sha512)

        XCTAssertEqual(
            rewritten.rawQuery,
            "step=45&step=99&key=NEW&encoding=Base32&size=8&otpHashMode=SHA512"
        )
    }

    private func titles(_ entries: [KPEntry]) -> [String] {
        entries.map(\.title)
    }
}
