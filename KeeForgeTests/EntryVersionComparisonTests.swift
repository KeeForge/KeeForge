import CryptoKit
import OneTimeCodes
import XCTest
@testable import KeeForge

@MainActor
final class EntryVersionComparisonTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    func testAnIdenticalVersionDiffersInNothing() throws {
        let entry = try makeEntry()
        let comparison = compare(entry, entry)

        XCTAssertEqual(comparison.differences, [])
        XCTAssertEqual(comparison.differingFieldCount, 0)
    }

    func testEachFieldIsComparedAndUnprotectedOnesCarryTheCurrentValue() throws {
        let current = try makeEntry()
        var version = current
        version.title = "Github (work)"
        version.username = "alex"
        version.url = "https://github.com/old"
        version.notes = "Old notes"
        version.tags = ["legacy"]
        version.customFields["Hostname"] = "old.local"
        version.expires = false
        version.totpConfig = nil

        let comparison = compare(version, current)

        XCTAssertEqual(comparison.differences.map(\.field), [
            .title, .username, .website(0), .verificationCode, .custom("Hostname"), .notes, .tags, .expiry,
        ])
        XCTAssertEqual(comparison.differingFieldCount, 8)
        XCTAssertEqual(comparison.current(.title), .text("GitHub"))
        XCTAssertEqual(comparison.current(.username), .text("alexrivers"))
        XCTAssertEqual(comparison.current(.website(0)), .text("https://github.com"))
        XCTAssertEqual(comparison.current(.verificationCode), .concealed, "A code's secret is never shown")
        XCTAssertEqual(comparison.current(.custom("Hostname")), .text("db.local"))
        XCTAssertEqual(comparison.current(.notes), .text("Line one"))
        XCTAssertEqual(comparison.current(.tags), .tags(["2fa", "work"]))
        XCTAssertEqual(comparison.current(.expiry), .date(Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertFalse(comparison.differs(.password))
    }

    func testProtectedFieldsOnlySayTheyDiffer() throws {
        let current = try makeEntry()
        var version = current
        version.password = try EncryptedValue.encrypt("old-password", using: key)
        version.customFields["Deploy Token"] = "old-token"
        version.totpConfig = TOTPConfig(secret: try EncryptedValue.encrypt("GEZDGNBVGY3TQOJQ", using: key))

        let comparison = compare(version, current)

        XCTAssertEqual(comparison.differences, [
            .init(field: .password, current: .concealed),
            .init(field: .verificationCode, current: .concealed),
            .init(field: .custom("Deploy Token"), current: .concealed),
        ])
    }

    func testAPasswordReEncryptedWithTheSameValueDoesNotDiffer() throws {
        let current = try makeEntry()
        var version = current
        version.password = try EncryptedValue.encrypt("hunter2", using: key)
        version.totpConfig = TOTPConfig(secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: key), digits: 6)

        XCTAssertEqual(compare(version, current).differences, [])
    }

    func testAFieldProtectedInEitherVersionOrReachingAProtectedReferenceIsConcealed() throws {
        let current = try makeEntry()
        var version = current
        version.customFields["Hostname"] = "old.local"
        version.protectedStringKeys.insert("Hostname")
        version.username = "old"
        version.notes = "old"

        let comparison = compare(version, current, displayValue: { $0 == "Line one" ? nil : $0 })

        XCTAssertEqual(comparison.current(.custom("Hostname")), .concealed, "Protected in the version")
        XCTAssertEqual(comparison.current(.notes), .concealed, "Its reference needs a protected value")
        XCTAssertEqual(comparison.current(.username), .text("alexrivers"))

        var protectedUsername = current
        protectedUsername.protectedStringKeys.insert("UserName")
        XCTAssertEqual(compare(version, protectedUsername).current(.username), .concealed)
    }

    func testWebsitesAreComparedByPositionAndMissingValuesAreNone() throws {
        let current = try makeEntry()
        var version = current
        version.customFields["KP2A_URL_1"] = "https://status.github.com"
        version.customFields["KP2A_URL_2"] = "https://docs.github.com"

        var comparison = compare(version, current)
        XCTAssertEqual(comparison.differences.map(\.field), [.website(2)])
        XCTAssertEqual(comparison.current(.website(2)), .empty, "The current entry has no third website")

        var reordered = current
        reordered.customFields["KP2A_URL_1"] = "https://docs.github.com"
        reordered.customFields["KP2A_URL_2"] = "https://status.github.com"
        comparison = compare(version, reordered)
        XCTAssertEqual(comparison.differences.map(\.field), [.website(1), .website(2)])
        XCTAssertEqual(comparison.current(.website(1)), .text("https://docs.github.com"))
    }

    func testCustomFieldsOnlyOneSideHasAreDifferencesInCurrentOrderThenTheVersions() throws {
        let current = try makeEntry()
        var version = current
        version.customFields.removeValue(forKey: "Hostname")
        version.customFields["Retired"] = "gone"
        version.customFieldOrder = ["Deploy Token", "Retired"]

        let comparison = compare(version, current)

        XCTAssertEqual(comparison.differences.map(\.field), [.custom("Hostname"), .custom("Retired")])
        XCTAssertEqual(comparison.current(.custom("Hostname")), .text("db.local"))
        XCTAssertEqual(comparison.current(.custom("Retired")), .empty)
    }

    func testTagOrderAloneIsNoDifference() throws {
        let current = try makeEntry()
        var version = current
        version.tags = ["work", "2fa"]
        XCTAssertFalse(compare(version, current).differs(.tags))
    }

    // MARK: - Helpers

    private func compare(
        _ version: KPEntry, _ current: KPEntry, displayValue: (String) -> String? = { $0 }
    ) -> EntryVersionComparison {
        EntryVersionComparison(version: version, current: current, sessionKey: key, displayValue: displayValue)
    }

    private func makeEntry() throws -> KPEntry {
        KPEntry(
            title: "GitHub",
            username: "alexrivers",
            password: try EncryptedValue.encrypt("hunter2", using: key),
            url: "https://github.com",
            notes: "Line one",
            tags: ["2fa", "work"],
            customFields: [
                "KP2A_URL_1": "https://status.github.com",
                "Hostname": "db.local",
                "Deploy Token": "tok-123",
            ],
            customFieldOrder: ["Hostname", "Deploy Token"],
            totpConfig: TOTPConfig(secret: try EncryptedValue.encrypt("JBSWY3DPEHPK3PXP", using: key)),
            expires: true,
            expiryTime: Date(timeIntervalSince1970: 1_800_000_000),
            protectedStringKeys: ["Password", "Deploy Token"]
        )
    }
}
