import CryptoKit
import CommonCrypto
import XCTest
@testable import KeeForge

final class KDBXParserTests: XCTestCase {
    private let fixturePassword = "testpassword123"
    private let legacyFixturePassword = "testpassword123"
    private let testSessionKey = SymmetricKey(size: .bits256)

    // MARK: - Fixture Expectations

    /// Expected entries in test.kdbx — ground truth from keepassxc-cli / pykeepass
    private struct Expected {
        struct EntryData {
            let group: String
            let title: String
            let username: String
            let password: String
            let url: String
            let notes: String
            let hasTOTP: Bool
            let totpSecret: String?
        }

        static let entries: [EntryData] = [
            EntryData(
                group: "Social", title: "Twitter",
                username: "testuser", password: "twitterpass123",
                url: "https://twitter.com", notes: "",
                hasTOTP: false, totpSecret: nil
            ),
            EntryData(
                group: "Social", title: "Discord",
                username: "gamer123", password: "discordpass!@#",
                url: "https://discord.com", notes: "Gaming account",
                hasTOTP: true, totpSecret: "GEZDGNBVGY3TQOJQ"
            ),
            EntryData(
                group: "Social", title: "Offline Key",
                username: "", password: "physical-key-backup",
                url: "", notes: "Stored in safe deposit box\nBox #42\nBank: Chase\n" + String(repeating: "A", count: 200),
                hasTOTP: false, totpSecret: nil
            ),
            EntryData(
                group: "Social", title: "Public Profile",
                username: "crazytan", password: "",
                url: "https://keybase.io/crazytan", notes: "",
                hasTOTP: false, totpSecret: nil
            ),
            EntryData(
                group: "Work", title: "Email",
                username: "work@example.com", password: "workpass456",
                url: "https://mail.example.com", notes: "",
                hasTOTP: false, totpSecret: nil
            ),
            EntryData(
                group: "Work", title: "GitHub",
                username: "devuser", password: "githubpass789",
                url: "https://github.com", notes: "",
                hasTOTP: true, totpSecret: "JBSWY3DPEHPK3PXP"
            ),
            EntryData(
                group: "Internal", title: "日本語テスト 🔑",
                username: "ユーザー", password: "pässwörd!@#¥",
                url: "https://example.jp", notes: "",
                hasTOTP: false, totpSecret: nil
            ),
        ]

        static let groups = ["Social", "Work", "Empty", "Internal"]
    }

    // MARK: - Structure Tests

    func testParseFindsAllGroups() throws {
        let root = try parseFixture()
        let groupNames = Set(allGroupNames(in: root))

        for name in Expected.groups {
            XCTAssertTrue(groupNames.contains(name), "Missing group: \(name)")
        }
    }

    func testParseFindsCorrectEntryCount() throws {
        let root = try parseFixture()
        XCTAssertEqual(root.allEntries.count, Expected.entries.count,
                       "Expected \(Expected.entries.count) entries, got \(root.allEntries.count)")
    }

    // MARK: - No Duplicates (History entries must be excluded)

    func testNoDuplicateEntries() throws {
        // test.kdbx has 2 history versions inside the Twitter entry.
        // Without proper History filtering, the parser would return 6 entries instead of 4.
        let root = try parseFixture()
        let entries = root.allEntries

        XCTAssertEqual(entries.count, Expected.entries.count,
                       "Expected \(Expected.entries.count) entries but got \(entries.count) — history entries may be leaking")

        // Each title+username combo should appear exactly once
        let keys = entries.map { "\($0.title)|\($0.username)" }
        let uniqueKeys = Set(keys)
        XCTAssertEqual(keys.count, uniqueKeys.count,
                       "Duplicate entries found: \(keys)")
    }

    func testHistoryEntriesAreAttachedToOwningEntry() throws {
        let root = try parseFixture()
        let twitter = try XCTUnwrap(root.allEntries.first { $0.title == "Twitter" })

        XCTAssertEqual(twitter.history.count, 2)
        XCTAssertTrue(twitter.history.allSatisfy { $0.history.isEmpty })
        for historyEntry in twitter.history {
            XCTAssertFalse(try historyEntry.password.decrypt(using: testSessionKey).isEmpty)
        }
    }

    // MARK: - Entry Field Tests

    func testAllEntryUsernames() throws {
        let root = try parseFixture()
        let entries = root.allEntries

        for expected in Expected.entries {
            let entry = entries.first { $0.title == expected.title }
            XCTAssertNotNil(entry, "Entry not found: \(expected.title)")
            XCTAssertEqual(entry?.username, expected.username,
                           "\(expected.title): username mismatch")
        }
    }

    func testAllEntryPasswords() throws {
        let root = try parseFixture()
        let entries = root.allEntries

        for expected in Expected.entries {
            let entry = entries.first { $0.title == expected.title }
            XCTAssertNotNil(entry, "Entry not found: \(expected.title)")
            let decrypted = try entry?.password.decrypt(using: testSessionKey)
            XCTAssertEqual(decrypted, expected.password,
                           "\(expected.title): password mismatch — inner stream decryption may be broken")
        }
    }

    func testAllEntryURLs() throws {
        let root = try parseFixture()
        let entries = root.allEntries

        for expected in Expected.entries {
            let entry = entries.first { $0.title == expected.title }
            XCTAssertNotNil(entry, "Entry not found: \(expected.title)")
            XCTAssertEqual(entry?.url, expected.url,
                           "\(expected.title): URL mismatch")
        }
    }

    func testAllEntryNotes() throws {
        let root = try parseFixture()
        let entries = root.allEntries

        for expected in Expected.entries {
            let entry = entries.first { $0.title == expected.title }
            XCTAssertNotNil(entry, "Entry not found: \(expected.title)")
            XCTAssertEqual(entry?.notes, expected.notes,
                           "\(expected.title): notes mismatch")
        }
    }

    // MARK: - TOTP Tests

    func testEntriesWithTOTPHaveConfig() throws {
        let root = try parseFixture()
        let entries = root.allEntries

        for expected in Expected.entries where expected.hasTOTP {
            let entry = entries.first { $0.title == expected.title }
            XCTAssertNotNil(entry, "Entry not found: \(expected.title)")
            XCTAssertNotNil(entry?.totpConfig,
                            "\(expected.title): expected TOTP config but got nil")
            let decryptedSecret = try entry?.totpConfig?.secret.decrypt(using: testSessionKey)
            XCTAssertEqual(decryptedSecret, expected.totpSecret,
                           "\(expected.title): TOTP secret mismatch")
        }
    }

    func testEntriesWithoutTOTPHaveNoConfig() throws {
        let root = try parseFixture()
        let entries = root.allEntries

        for expected in Expected.entries where !expected.hasTOTP {
            let entry = entries.first { $0.title == expected.title }
            XCTAssertNotNil(entry, "Entry not found: \(expected.title)")
            XCTAssertNil(entry?.totpConfig,
                         "\(expected.title): should not have TOTP config")
        }
    }

    // MARK: - KeeOTP TOTP Compatibility

    func testKeeOTPEligibleFieldNamesAndQueryDecoding() throws {
        for fieldName in ["otp", "OTP", "Otp"] {
            let entry = try parseSingleEntry(fields: [
                fieldName: "key=hello%20world&type=TOTP&step=30&size=6&encoding=UTF8&otpHashMode=SHA1",
            ])

            let config = try XCTUnwrap(entry.totpConfig, "Expected KeeOTP config for \(fieldName)")
            XCTAssertEqual(config.period, 30)
            XCTAssertEqual(config.digits, 6)
            XCTAssertEqual(config.algorithm, .sha1)
            XCTAssertEqual(TOTPGenerator.resolveSecret(config: config, sessionKey: testSessionKey)?.data, Data("hello world".utf8))
            XCTAssertEqual(config.keeOTPSource, KeeOTPSource(fieldName: fieldName, rawQuery: "key=hello%20world&type=TOTP&step=30&size=6&encoding=UTF8&otpHashMode=SHA1"))
            XCTAssertNil(entry.displayCustomFields[fieldName])
        }
    }

    func testKeeOTPSupportsEachDeclaredEncodingWithoutFallback() throws {
        let cases: [(String, String, Data)] = [
            ("Base32", "JBSWY3DP", Data("Hello".utf8)),
            ("Base32", "jbswy3dp", Data("Hello".utf8)), // KeeOtp2 emits lowercase Base32 keys.
            ("Base64", "AAEC/w==", Data([0x00, 0x01, 0x02, 0xFF])),
            ("Hex", "000102ff", Data([0x00, 0x01, 0x02, 0xFF])),
            ("UTF8", "p%C3%A4ss", Data("päss".utf8)),
        ]

        for (encoding, key, expected) in cases {
            let entry = try parseSingleEntry(fields: [
                "otp": "key=\(key)&type=TOTP&step=30&size=8&encoding=\(encoding)&otpHashMode=SHA256",
            ])
            let config = try XCTUnwrap(entry.totpConfig, "Expected \(encoding) config")
            XCTAssertEqual(TOTPGenerator.resolveSecret(config: config, sessionKey: testSessionKey)?.data, expected)
        }

        XCTAssertNil(try parseSingleEntry(fields: [
            "otp": "key=JBSWY3DP====&type=TOTP&step=30&size=6&encoding=Base64&otpHashMode=SHA1",
        ]).totpConfig, "A Base32-looking key must not fall back from declared Base64")

        XCTAssertNil(try parseSingleEntry(fields: [
            "otp": "key=AAEC/w===&type=TOTP&step=30&size=6&encoding=Base64&otpHashMode=SHA1",
        ]).totpConfig, "Over-padded Base64 must be rejected")
    }

    func testKeeOTPRejectsIneligibleMalformedDuplicateAndHOTPInputs() throws {
        let rejected = [
            ["Other": "key=JBSWY3DP&type=TOTP&step=30&size=6&encoding=Base32&otpHashMode=SHA1"],
            ["otp": "prefix=1&key=JBSWY3DP&type=TOTP&step=30&size=6&encoding=Base32&otpHashMode=SHA1"],
            ["otp": "key=&type=TOTP&step=30&size=6&encoding=UTF8&otpHashMode=SHA1"],
            ["otp": "key=JBS%20WY3DP&type=TOTP&step=30&size=6&encoding=Base32&otpHashMode=SHA1"],
            ["otp": "key=JBSWY3DP%3D&type=TOTP&step=30&size=6&encoding=Base32&otpHashMode=SHA1"],
            ["otp": "key=JBSWY3DK&type=TOTP&step=30&size=6&encoding=Base32&otpHashMode=SHA1"],
            ["otp": "key=JBSWY3Dı&type=TOTP&step=30&size=6&encoding=Base32&otpHashMode=SHA1"],
            ["otp": "key=JBŚWY3DP&type=TOTP&step=30&size=6&encoding=Base32&otpHashMode=SHA1"],
            ["otp": "key=MZ&type=TOTP&step=30&size=6&encoding=Base32&otpHashMode=SHA1"],
            ["otp": "key=***&type=TOTP&step=30&size=6&encoding=Base32&otpHashMode=SHA1"],
            ["otp": "key=0g&type=TOTP&step=30&size=6&encoding=Hex&otpHashMode=SHA1"],
            ["otp": "key=abc&type=TOTP&step=30&size=6&encoding=Unknown&otpHashMode=SHA1"],
            ["otp": "key=abc&type=HOTP&step=30&size=6&encoding=UTF8&otpHashMode=SHA1&counter=4"],
            ["otp": "key=abc&type=TOTP&step=0&size=6&encoding=UTF8&otpHashMode=SHA1"],
            ["otp": "key=abc&type=TOTP&step=30&size=7&encoding=UTF8&otpHashMode=SHA1"],
            ["otp": "key=abc&type=TOTP&step=30&size=6&encoding=UTF8&otpHashMode=MD5"],
            ["otp": "key=abc&key=def&type=TOTP&step=30&size=6&encoding=UTF8&otpHashMode=SHA1"],
        ]

        for fields in rejected {
            XCTAssertNil(try parseSingleEntry(fields: fields).totpConfig, "Unexpected config for \(fields)")
        }
    }

    func testEstablishedOTPSourceKeepsPrecedenceOverKeeOTP() throws {
        let entry = try parseSingleEntry(fields: [
            "otp": "otpauth://totp/Test?secret=JBSWY3DP&digits=8",
            "OTP": "key=other&type=TOTP&step=60&size=6&encoding=UTF8&otpHashMode=SHA512",
        ])

        let config = try XCTUnwrap(entry.totpConfig)
        XCTAssertEqual(config.digits, 8)
        XCTAssertEqual(config.period, 30)
        XCTAssertEqual(try config.secret.decrypt(using: testSessionKey), "JBSWY3DP")
        XCTAssertNil(config.keeOTPSource)
        XCTAssertEqual(
            entry.customFields["OTP"],
            "key=other&type=TOTP&step=60&size=6&encoding=UTF8&otpHashMode=SHA512",
            "A KeeOTP field that is not the active TOTP source must stay in customFields so it survives saves"
        )
    }

    func testKeeOTPAppliesKeeOtp2DefaultsForOmittedParameters() throws {
        // KeeOtp2 only writes non-default parameters; a plain TOTP entry is
        // just "key=SECRET" and "type" is only ever written for HOTP.
        let minimal = try parseSingleEntry(fields: ["otp": "key=JBSWY3DP"])
        let config = try XCTUnwrap(minimal.totpConfig, "Minimal KeeOTP payloads must be recognized")
        XCTAssertEqual(config.period, 30)
        XCTAssertEqual(config.digits, 6)
        XCTAssertEqual(config.algorithm, .sha1)
        XCTAssertEqual(TOTPGenerator.resolveSecret(config: config, sessionKey: testSessionKey)?.data, Data("Hello".utf8))
        XCTAssertEqual(config.keeOTPSource, KeeOTPSource(fieldName: "otp", rawQuery: "key=JBSWY3DP"))

        let partial = try parseSingleEntry(fields: ["OTP": "key=JBSWY3DP&step=45"])
        let partialConfig = try XCTUnwrap(partial.totpConfig)
        XCTAssertEqual(partialConfig.period, 45)
        XCTAssertEqual(partialConfig.digits, 6)

        XCTAssertNil(
            try parseSingleEntry(fields: ["otp": "key=JBSWY3DP&type=HOTP&counter=4"]).totpConfig,
            "HOTP payloads must be rejected even when other parameters are omitted"
        )
        XCTAssertNil(
            try parseSingleEntry(fields: ["otp": "key=JBSWY3DP&step=abc"]).totpConfig,
            "Present-but-invalid parameters must still be rejected"
        )
    }

    func testInvalidOTPAndOtpCustomFieldsRemainVisible() throws {
        for fieldName in ["OTP", "Otp"] {
            let entry = try parseSingleEntry(fields: [fieldName: "ordinary custom value"])
            XCTAssertEqual(entry.displayCustomFields[fieldName], "ordinary custom value")
            XCTAssertNil(entry.totpConfig)
        }
    }

    func testNativeAndLegacyTOTPBaselinesRemainSupported() throws {
        let native = try parseSingleEntry(fields: [
            "TimeOtp-Secret-Base32": "JBSWY3DP", "TimeOtp-Period": "45", "TimeOtp-Length": "8",
        ])
        XCTAssertEqual(native.totpConfig?.period, 45)
        XCTAssertEqual(native.totpConfig?.digits, 8)

        let legacy = try parseSingleEntry(fields: ["TOTP Seed": "JBSWY3DP", "TOTP Settings": "60;6"])
        XCTAssertEqual(legacy.totpConfig?.period, 60)
        XCTAssertEqual(legacy.totpConfig?.digits, 6)

        let unsupportedOTPURI = try parseSingleEntry(fields: ["otp": "otp://totp/Test?secret=JBSWY3DP"])
        XCTAssertNil(unsupportedOTPURI.totpConfig, "otp:// has no existing parser path to preserve")
    }

    func testOTPAuthURIDuplicateQueryNamesDoNotTrapFirstWins() throws {
        // Duplicate query names (including case-folded duplicates) previously
        // fed `Dictionary(uniqueKeysWithValues:)` and crashed the unlock parse.
        let entry = try parseSingleEntry(fields: [
            "otp": "otpauth://totp/Test?secret=JBSWY3DP&Secret=OTHER&period=45&period=60",
        ])

        let config = try XCTUnwrap(entry.totpConfig)
        XCTAssertEqual(try config.secret.decrypt(using: testSessionKey), "JBSWY3DP")
        XCTAssertEqual(config.period, 45)
    }

    func testFileSuppliedTOTPTimingValuesAreSanitized() throws {
        // Zero/negative periods previously divided by zero in `TOTPGenerator`,
        // and digit counts above 9 overflowed the 10^digits modulus.
        let uri = try parseSingleEntry(fields: [
            "otp": "otpauth://totp/Test?secret=JBSWY3DP&period=0&digits=20",
        ])
        XCTAssertEqual(uri.totpConfig?.period, 30)
        XCTAssertEqual(uri.totpConfig?.digits, 6)

        let native = try parseSingleEntry(fields: [
            "TimeOtp-Secret-Base32": "JBSWY3DP", "TimeOtp-Period": "-5", "TimeOtp-Length": "0",
        ])
        XCTAssertEqual(native.totpConfig?.period, 30)
        XCTAssertEqual(native.totpConfig?.digits, 6)

        let legacy = try parseSingleEntry(fields: ["TOTP Seed": "JBSWY3DP", "TOTP Settings": "0;12"])
        XCTAssertEqual(legacy.totpConfig?.period, 30)
        XCTAssertEqual(legacy.totpConfig?.digits, 6)
    }

    // MARK: - Group Membership Tests

    func testEntriesAreInCorrectGroups() throws {
        let root = try parseFixture()

        for expected in Expected.entries {
            let group = findGroup(named: expected.group, in: root)
            XCTAssertNotNil(group, "Group not found: \(expected.group)")
            let entryInGroup = group?.entries.first { $0.title == expected.title }
            XCTAssertNotNil(entryInGroup,
                            "\(expected.title) should be in group \(expected.group)")
        }
    }

    // MARK: - Nested Groups

    func testNestedSubgroupParsed() throws {
        let root = try parseFixture()
        let work = findGroup(named: "Work", in: root)
        XCTAssertNotNil(work)
        let internal_ = work?.groups.first { $0.name == "Internal" }
        XCTAssertNotNil(internal_, "Nested group Work/Internal not found")
        XCTAssertEqual(internal_?.entries.count, 1)
    }

    func testEmptyGroupHasNoEntries() throws {
        let root = try parseFixture()
        let empty = findGroup(named: "Empty", in: root)
        XCTAssertNotNil(empty, "Empty group not found")
        XCTAssertTrue(empty?.entries.isEmpty ?? false)
    }

    func testAllEntriesIncludesNestedGroupEntries() throws {
        let root = try parseFixture()
        let nestedEntry = try XCTUnwrap(
            root.allEntries.first { $0.title == "日本語テスト 🔑" },
            "Entry in nested group not found via allEntries"
        )
        // This entry lives in Work/Internal; asserting its actual field
        // content (not just non-nil) proves allEntries recursed into the
        // nested subgroup rather than matching an unrelated entry.
        XCTAssertEqual(nestedEntry.username, "ユーザー")
        XCTAssertEqual(nestedEntry.url, "https://example.jp")
    }

    // MARK: - Edge Cases

    func testEntryWithEmptyURLAndUsername() throws {
        let root = try parseFixture()
        let entry = root.allEntries.first { $0.title == "Offline Key" }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.url, "")
        XCTAssertEqual(entry?.username, "")
    }

    func testEntryWithEmptyPassword() throws {
        let root = try parseFixture()
        let entry = root.allEntries.first { $0.title == "Public Profile" }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.hasPassword, false)
    }

    func testUnicodeEntryFieldsParsedCorrectly() throws {
        let root = try parseFixture()
        let entry = root.allEntries.first { $0.title == "日本語テスト 🔑" }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.username, "ユーザー")
        let decrypted = try entry?.password.decrypt(using: testSessionKey)
        XCTAssertEqual(decrypted, "pässwörd!@#¥")
    }

    // MARK: - KP2A Additional URLs

    func testGitHubEntryHasAdditionalURLs() throws {
        let root = try parseFixture()
        let github = try XCTUnwrap(root.allEntries.first { $0.title == "GitHub" })

        XCTAssertEqual(github.additionalURLs, [
            "https://github.com/settings",
            "https://gist.github.com",
        ])
    }

    func testEntriesWithoutKP2AURLsHaveEmptyAdditionalURLs() throws {
        let root = try parseFixture()
        let twitter = try XCTUnwrap(root.allEntries.first { $0.title == "Twitter" })
        XCTAssertTrue(twitter.additionalURLs.isEmpty)
    }

    func testKP2AURLFieldsRetainedInCustomFields() throws {
        let root = try parseFixture()
        let github = try XCTUnwrap(root.allEntries.first { $0.title == "GitHub" })

        // KP2A_URL_* fields are NOT stripped from the raw customFields
        // dictionary during parsing — additionalURLs derives directly from
        // them, so parsing must preserve both the keys and their values.
        let kp2aFields = github.customFields.filter { $0.key.hasPrefix("KP2A_URL_") }
        XCTAssertEqual(
            Set(kp2aFields.values),
            Set(["https://github.com/settings", "https://gist.github.com"])
        )
    }

    func testKP2AURLsAreSortedByKey() {
        let entry = KPEntry(
            title: "Unordered",
            customFields: [
                "KP2A_URL_3": "https://three.example.com",
                "KP2A_URL_1": "https://one.example.com",
                "KP2A_URL_2": "https://two.example.com",
            ]
        )

        XCTAssertEqual(entry.additionalURLs, [
            "https://one.example.com",
            "https://two.example.com",
            "https://three.example.com",
        ])
    }

    // MARK: - Crypto Tests

    func testArgon2KeyDerivationKnownVector() throws {
        let derived = try Argon2.hash(
            password: Data("password".utf8),
            salt: Data("somesalt".utf8),
            timeCost: 2,
            memoryCost: 65_536,
            parallelism: 1,
            hashLength: 32,
            version: .v13,
            variant: .d
        )

        XCTAssertEqual(
            derived.hexString,
            "955e5d5b163a1b60bba35fc36d0496474fba4f6b59ad53628666f07fb2f93eaf"
        )
    }

    // MARK: - KDBX 3.1 Compatibility

    func testKDBX31PasswordOnlyDatabaseOpens() throws {
        let data = try legacyFixtureData()
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data,
            password: legacyFixturePassword,
            sessionKey: testSessionKey
        )

        XCTAssertEqual(parsed.header.formatVersion, .kdbx3_1)
        XCTAssertEqual(parsed.rootGroup.groups.map(\.name), ["Passwords"])
        XCTAssertEqual(parsed.rootGroup.groups.first?.groups.map(\.name), ["Social", "Work"])
        XCTAssertEqual(parsed.rootGroup.allEntries.count, 5)
    }

    func testKDBX31ProtectedFieldsDecrypt() throws {
        let root = try KDBXParser.parse(
            data: legacyFixtureData(),
            password: legacyFixturePassword,
            sessionKey: testSessionKey
        )
        let entriesByTitle = Dictionary(uniqueKeysWithValues: root.allEntries.map { ($0.title, $0) })

        XCTAssertEqual(entriesByTitle["Twitter"]?.username, "jia_tan")
        XCTAssertEqual(try entriesByTitle["Twitter"]?.password.decrypt(using: testSessionKey), "tw1tterP@ss!")
        XCTAssertEqual(try entriesByTitle["GitHub"]?.password.decrypt(using: testSessionKey), "g1thubS3cure#")
        XCTAssertEqual(try entriesByTitle["Email"]?.password.decrypt(using: testSessionKey), "w0rkM@il2024")
        XCTAssertEqual(try entriesByTitle["KeeVault"]?.password.decrypt(using: testSessionKey), "k33v@ultDev!")
        XCTAssertFalse(entriesByTitle["Slack"]?.hasPassword ?? true)
    }

    // MARK: - KDBX 3.1 Salsa20 inner stream

    /// Known-answer vectors for the legacy Salsa20 inner random stream: key =
    /// SHA-256(inner stream key), nonce = the fixed KDBX `E830094B97205D2A`,
    /// one keystream spanning every protected value in document order.
    ///
    /// The fixed nonce rules out the published ECRYPT/eSTREAM vectors directly,
    /// so these ciphertexts were produced with PyCryptodome's Salsa20 —
    /// independent of this codebase, and first verified against ECRYPT/eSTREAM
    /// Set 6 vector #0 (key `0053A6F9…BA0D`, IV `0D74DB42A91077DE`, keystream
    /// `F5FAD53F79F9DF58…B1280B71`).
    ///
    /// Lengths straddle the 64-byte block boundary (63/1/64/65) and include a
    /// multi-block run, so a counter or offset slip cannot pass.
    func testKDBX31Salsa20InnerStreamMatchesKnownAnswerVectors() throws {
        let entry = try parseSalsa20ProtectedValues(interleavingEmptyValues: false)

        for vector in Self.salsa20Vectors {
            XCTAssertEqual(entry.customFields[vector.key], vector.plaintext, "protected value \(vector.key)")
        }
    }

    /// An empty protected value must not consume keystream, otherwise every
    /// later value in the document decodes against a shifted stream.
    func testKDBX31Salsa20InnerStreamEmptyProtectedValueDoesNotAdvanceStream() throws {
        let entry = try parseSalsa20ProtectedValues(interleavingEmptyValues: true)

        for vector in Self.salsa20Vectors {
            XCTAssertEqual(entry.customFields[vector.key], vector.plaintext, "protected value \(vector.key)")
        }
        XCTAssertEqual(entry.customFields["Empty0"], "")
    }

    func testKDBX31TwofishDatabaseOpensReadOnly() throws {
        let data = try makeLegacyTwofishFixture()
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data,
            password: legacyFixturePassword,
            sessionKey: testSessionKey
        )

        XCTAssertEqual(parsed.header.formatVersion, .kdbx3_1)
        XCTAssertEqual(parsed.header.cipherID, KDBXParser.twofishCipherUUID)
        XCTAssertTrue(parsed.header.formatVersion.requiresReadOnlyMode)
        XCTAssertEqual(parsed.rootGroup.allEntries.count, 5)
        let twitter = try XCTUnwrap(parsed.rootGroup.allEntries.first { $0.title == "Twitter" })
        XCTAssertEqual(try twitter.password.decrypt(using: testSessionKey), "tw1tterP@ss!")
    }

    func testKDBX31WrongPasswordFailsCleanly() throws {
        let data = try legacyFixtureData()

        XCTAssertThrowsError(
            try KDBXParser.parse(data: data, password: "definitely-wrong", sessionKey: testSessionKey)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                String(localized: "Decryption failed — wrong password?"),
                "Expected a friendly wrong-password failure, got: \(error.localizedDescription)"
            )
        }
    }

    func testChaChaDecryptRejectsInvalidNonce() throws {
        XCTAssertThrowsError(
            try KDBXCrypto.decryptChaCha20(
                data: Data(repeating: 0x01, count: 32),
                key: Data(repeating: 0x02, count: 32),
                nonce: Data(repeating: 0x03, count: 8)
            )
        ) { error in
            guard case KDBXCrypto.CryptoError.decryptionFailed = error else {
                XCTFail("Expected normalized ChaCha decrypt failure, got \(error)")
                return
            }
        }
    }

    func testKDBX31CorruptedHashedBlockFails() throws {
        let corrupted = try makeLegacyFixtureWithCorruptedHashedBlock()

        XCTAssertThrowsError(
            try KDBXParser.parse(data: corrupted, password: legacyFixturePassword, sessionKey: testSessionKey)
        ) { error in
            XCTAssertEqual(error as? KDBXParser.ParseError, .invalidLegacyBlockHash)
        }
    }

    // MARK: - Security: KDBX4 Integrity Enforcement

    /// A freshly written KDBX 4 database plus the offsets a corruption test
    /// needs. Written in-test (not a bundled fixture) so the header layout is
    /// exactly the one `KDBXWriter` produces, and with weak Argon2id
    /// parameters so five parse attempts stay fast.
    private struct KDBX4IntegrityFixture {
        let data: Data
        let password: String
        let keyFileData: Data
        let masterSeed: Data
        /// Byte count of the outer header, i.e. the offset of the stored
        /// header SHA-256.
        let headerLength: Int
        /// First byte of the HMAC-block stream (header + SHA-256 + HMAC).
        var payloadStart: Int { headerLength + 64 }
    }

    func testKDBX4CorruptedPayloadBlockFailsBlockHMAC() throws {
        let fixture = try makeKDBX4IntegrityFixture()

        // Layout of the first HMAC block: [32-byte HMAC][4-byte size][data].
        let ciphertextOffset = fixture.payloadStart + 36
        XCTAssertLessThan(ciphertextOffset, fixture.data.count)
        var corrupted = fixture.data
        corrupted[ciphertextOffset] ^= 0x01

        XCTAssertThrowsError(
            try KDBXParser.parse(
                data: corrupted,
                password: fixture.password,
                keyFileData: fixture.keyFileData,
                sessionKey: testSessionKey
            )
        ) { error in
            XCTAssertEqual(error as? KDBXParser.ParseError, .invalidBlockHMAC)
        }
    }

    func testKDBX4CorruptedOuterHeaderFailsHeaderSHA256() throws {
        let fixture = try makeKDBX4IntegrityFixture()

        // Flip a byte inside the master seed value: the header still parses,
        // so the failure has to come from the integrity check rather than the
        // TLV reader. The header SHA-256 is verified before the header HMAC,
        // so a header bit flip surfaces as `.invalidSignature`.
        let seedRange = try XCTUnwrap(fixture.data.range(of: fixture.masterSeed))
        XCTAssertLessThan(seedRange.lowerBound, fixture.headerLength)
        var corrupted = fixture.data
        corrupted[seedRange.lowerBound] ^= 0x01

        XCTAssertThrowsError(
            try KDBXParser.parse(
                data: corrupted,
                password: fixture.password,
                keyFileData: fixture.keyFileData,
                sessionKey: testSessionKey
            )
        ) { error in
            XCTAssertEqual(error as? KDBXParser.ParseError, .invalidSignature)
        }
    }

    func testKDBX4PayloadTruncatedMidBlockFailsAsTruncated() throws {
        let fixture = try makeKDBX4IntegrityFixture()

        let blockSize = fixture.data
            .subdata(in: (fixture.payloadStart + 32)..<(fixture.payloadStart + 36))
            .withUnsafeBytes { $0.loadUnaligned(as: Int32.self).littleEndian }
        XCTAssertGreaterThan(blockSize, 2)
        let truncated = Data(fixture.data.prefix(fixture.payloadStart + 36 + Int(blockSize) / 2))

        XCTAssertThrowsError(
            try KDBXParser.parse(
                data: truncated,
                password: fixture.password,
                keyFileData: fixture.keyFileData,
                sessionKey: testSessionKey
            )
        ) { error in
            XCTAssertEqual(error as? KDBXParser.ParseError, .truncatedFile)
        }
    }

    func testKDBX4WrongPasswordAndWrongKeyFileBothFailHeaderHMAC() throws {
        let fixture = try makeKDBX4IntegrityFixture()

        // KDBX 4 verifies the header HMAC — which is keyed by the composite
        // key — before it touches a single payload block, so every bad
        // credential (wrong password, wrong key file, missing key file)
        // legitimately produces the same `CryptoError.hmacMismatch`.
        let badCredentials: [(name: String, password: String?, keyFileData: Data?)] = [
            ("wrong password", "definitely-wrong", fixture.keyFileData),
            ("wrong key file", fixture.password, Data("some-other-key-file".utf8)),
            ("missing key file", fixture.password, nil),
        ]

        for credentials in badCredentials {
            XCTAssertThrowsError(
                try KDBXParser.parse(
                    data: fixture.data,
                    password: credentials.password,
                    keyFileData: credentials.keyFileData,
                    sessionKey: testSessionKey
                ),
                "Expected \(credentials.name) to be rejected"
            ) { error in
                guard case KDBXCrypto.CryptoError.hmacMismatch = error else {
                    XCTFail("Expected header HMAC rejection for \(credentials.name), got \(error)")
                    return
                }
            }
        }
    }

    private func makeKDBX4IntegrityFixture() throws -> KDBX4IntegrityFixture {
        let password = "kdbx4-integrity"
        let keyFileData = Data("keeforge-kdbx4-integrity-key-file".utf8)
        let compositeKey = try KDBXCrypto.compositeKey(password: password, keyFileData: keyFileData)
        let rootGroup = KPGroup(
            name: "Root",
            groups: [
                KPGroup(
                    name: "Integrity",
                    entries: [
                        KPEntry(
                            title: "Integrity Entry",
                            username: "integrity-user",
                            password: try EncryptedValue.encrypt("integrity-secret", using: testSessionKey),
                            creationTime: Date(timeIntervalSince1970: 1_700_000_000),
                            lastModificationTime: Date(timeIntervalSince1970: 1_700_000_000)
                        )
                    ],
                    creationTime: Date(timeIntervalSince1970: 1_700_000_000),
                    lastModificationTime: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ]
        )

        let data = try KDBXWriter.write(
            rootGroup: rootGroup,
            meta: KPMeta(),
            compositeKey: compositeKey,
            freshHeader: KDBXWriter.FreshHeaderConfiguration(
                cipherID: KDBXParser.aesCipherUUID,
                kdfParameters: try KDBXCompatibilitySupport.fastArgon2idParameters()
            ),
            sessionKey: testSessionKey
        )

        // Baseline: the untouched file must open with the exact credentials,
        // otherwise the rejection assertions below prove nothing.
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data,
            password: password,
            keyFileData: keyFileData,
            sessionKey: testSessionKey
        )
        let entry = try XCTUnwrap(parsed.rootGroup.allEntries.first)
        XCTAssertEqual(entry.title, "Integrity Entry")
        XCTAssertEqual(try entry.password.decrypt(using: testSessionKey), "integrity-secret")

        var reader = DataReader(data: data)
        _ = try KDBXParser.parseVersion(from: &reader)
        _ = try KDBXParser.parseHeader(&reader)

        return KDBX4IntegrityFixture(
            data: data,
            password: password,
            keyFileData: keyFileData,
            masterSeed: parsed.header.masterSeed,
            headerLength: reader.offset
        )
    }

    func testUnsupportedLegacyInnerStreamShowsFriendlyError() throws {
        let data = try legacyFixtureData()
        let fieldValueOffset = try XCTUnwrap(legacyHeaderFieldValueOffset(fieldID: 10, in: data))
        var mutated = data
        mutated.replaceSubrange(fieldValueOffset..<(fieldValueOffset + 4), with: [0x01, 0x00, 0x00, 0x00])

        XCTAssertThrowsError(
            try KDBXParser.parse(data: mutated, password: legacyFixturePassword, sessionKey: testSessionKey)
        ) { error in
            XCTAssertEqual(error as? KDBXParser.ParseError, .unsupportedProtectedFieldStream(1))
            XCTAssertEqual(
                error.localizedDescription,
                String(localized: "This database uses an unsupported protected-field stream.")
            )
        }
    }

    func testAESKDFKeyDerivationKnownVector() throws {
        let compositeKey = Data((0..<32).map(UInt8.init))
        let seed = Data((32..<64).map(UInt8.init))
        let derived = try KDBXCrypto.transformKeyAESKDF(compositeKey: compositeKey, seed: seed, rounds: 10)

        XCTAssertEqual(
            derived.hexString,
            "f76f387e7538424a09d988e6f358824cd30d0dd35d0e8ecb1487ff6ffc1581cf"
        )
    }

    func testAESKDFMatchesReferenceImplementationAcrossRoundCounts() throws {
        let compositeKey = Data((0..<32).map(UInt8.init))
        let seed = Data((32..<64).map(UInt8.init))

        for rounds in [1, 2, 11, 257] {
            let derived = try KDBXCrypto.transformKeyAESKDF(
                compositeKey: compositeKey,
                seed: seed,
                rounds: UInt64(rounds)
            )

            XCTAssertEqual(
                derived,
                try referenceAESKDFTransform(
                    compositeKey: compositeKey,
                    seed: seed,
                    rounds: UInt64(rounds)
                ),
                "Mismatch at rounds=\(rounds)"
            )
        }
    }

    func testUnsupportedKDFErrorUsesFriendlyName() {
        let descriptor = KDFDescriptor(identifier: "c9d9f39a628a4460bf740d08c18a4fea", displayName: "AES-KDF")
        let error = KDBXCrypto.CryptoError.unsupportedKDF(descriptor)

        XCTAssertEqual(
            error.errorDescription,
            String(localized: "Unsupported key derivation function: \("AES-KDF")")
        )
    }

    func testGunzipKnownCompressedData() throws {
        let compressedBase64 = "H4sIAAAAAAAC//NOTQ1LLM0pUUgvzavKLFAoS00uyS9SKEiszMlPTOHKycxLNQIAX50mACQAAAA="
        let compressed = try XCTUnwrap(Data(base64Encoded: compressedBase64))

        let decompressed = try KDBXCrypto.gunzip(compressed)
        let text = String(data: decompressed, encoding: .utf8)

        XCTAssertEqual(text, "KeeVault gunzip vector payload\nline2")
    }

    // MARK: - Composite Key Tests

    func testCompositeKeyPathMatchesPasswordPath() throws {
        let data = try fixtureData()

        let parsedWithPassword = try KDBXParser.parse(data: data, password: fixturePassword, sessionKey: testSessionKey)
        let compositeKey = KDBXCrypto.compositeKey(password: fixturePassword)
        let parsedWithCompositeKey = try KDBXParser.parse(data: data, compositeKey: compositeKey, sessionKey: testSessionKey)

        XCTAssertEqual(
            allGroupNames(in: parsedWithPassword),
            allGroupNames(in: parsedWithCompositeKey)
        )
        XCTAssertEqual(parsedWithPassword.allEntries.count, parsedWithCompositeKey.allEntries.count)
    }

    // MARK: - Entry UUID Stability

    func testEntryUUIDsAreStableAcrossParses() throws {
        let data = try fixtureData()
        let root1 = try KDBXParser.parse(data: data, password: fixturePassword, sessionKey: SymmetricKey(size: .bits256))
        let root2 = try KDBXParser.parse(data: data, password: fixturePassword, sessionKey: SymmetricKey(size: .bits256))

        let entries1 = root1.allEntries.sorted { $0.title < $1.title }
        let entries2 = root2.allEntries.sorted { $0.title < $1.title }

        XCTAssertEqual(entries1.count, entries2.count)
        for (e1, e2) in zip(entries1, entries2) {
            XCTAssertEqual(e1.id, e2.id, "UUID mismatch for entry: \(e1.title)")
        }
    }

    func testEntryUUIDsAreUnique() throws {
        let root = try parseFixture()
        let ids = root.allEntries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Entry UUIDs should be unique")
    }

    // MARK: - Custom Icons

    func testCustomIconsParsedAndPreservedAsOpaqueXML() throws {
        let iconUUID = UUID()
        let iconUUIDBase64 = kpUUIDBase64(iconUUID)
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let xml = """
        <KeePassFile><Meta><Generator>Test</Generator>\
        <CustomIcons><Icon><UUID>\(iconUUIDBase64)</UUID><Data>\(pngBase64)</Data></Icon></CustomIcons>\
        </Meta><Root><Group><Name>Root</Name><CustomIconUUID>\(iconUUIDBase64)</CustomIconUUID>\
        <Entry><String><Key>Title</Key><Value>Custom</Value></String>\
        <CustomIconUUID>\(iconUUIDBase64)</CustomIconUUID></Entry>\
        </Group></Root></KeePassFile>
        """
        let parsed = try KDBXParser.parseXML(
            xmlData: Data(xml.utf8), innerStreamKey: Data(), innerStreamID: 0, sessionKey: testSessionKey
        )

        // The icon table is decoded for display…
        XCTAssertEqual(parsed.meta.customIcons[iconUUID], Data(base64Encoded: pngBase64))

        let group = try XCTUnwrap(parsed.rootGroup.groups.first)
        let entry = try XCTUnwrap(parsed.rootGroup.allEntries.first)
        XCTAssertEqual(group.customIconUUID, iconUUID)
        XCTAssertEqual(entry.customIconUUID, iconUUID)

        // …while the source elements stay in the opaque XML so the writer
        // round-trips them verbatim.
        XCTAssertTrue(parsed.meta.unknownXML.nodes.contains { $0.xml.contains("<CustomIcons>") })
        XCTAssertTrue(group.unknownXML.nodes.contains { $0.xml.contains("<CustomIconUUID>") })
        XCTAssertTrue(entry.unknownXML.nodes.contains { $0.xml.contains("<CustomIconUUID>") })
    }

    func testEntryWithoutCustomIconHasNilCustomIconUUID() throws {
        let entry = try parseSingleEntry(fields: [:])
        XCTAssertNil(entry.customIconUUID)
    }

    private func kpUUIDBase64(_ uuid: UUID) -> String {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }.base64EncodedString()
    }

    // MARK: - Foreign-Authored Outer Cipher Fixtures

    /// `compatibility/foreign-chacha20.kdbx` and `compatibility/foreign-twofish.kdbx`
    /// are authored by pykeepass (see
    /// `TestFixtures/compatibility/generate_foreign_cipher_fixtures.py`), an
    /// independent KDBX implementation, specifically to exercise KeeForge's
    /// ChaCha20 and Twofish outer-cipher READ paths against a database
    /// KeeForge did not write itself. Every other bundled fixture is
    /// AES-256-CBC, so without these two, a read failure on a user's
    /// foreign-authored ChaCha20/Twofish vault would be a total-access-loss
    /// bug with zero coverage. Both fixtures carry identical content: a
    /// root-level `Foreign` group with two entries, "Foreign Entry Alpha"
    /// (username `foreign-alpha-user`, password `ForeignAlphaSecret1`, one
    /// custom field `ForeignField` = `ForeignFieldValue`) and "Foreign Entry
    /// Beta" (username `foreign-beta-user`, password `ForeignBetaSecret2`,
    /// no custom field). Decrypting both entries' protected passwords also
    /// cross-validates the inner protected-value stream against a foreign
    /// author, independent of the outer cipher.
    func testForeignChaCha20FixtureParsesAndDecryptsProtectedValues() throws {
        try assertForeignCipherFixtureParses(
            named: "foreign-chacha20",
            password: "foreign-chacha20",
            expectedCipherUUID: KDBXParser.chachaCipherUUID
        )
    }

    func testForeignTwofishFixtureParsesAndDecryptsProtectedValues() throws {
        try assertForeignCipherFixtureParses(
            named: "foreign-twofish",
            password: "foreign-twofish",
            expectedCipherUUID: KDBXParser.twofishCipherUUID
        )
    }

    private func assertForeignCipherFixtureParses(
        named fixtureName: String,
        password: String,
        expectedCipherUUID: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bundle = Bundle(for: KDBXParserTests.self)
        let url = try TestDatabaseSupport.fixtureURL(named: fixtureName, subdirectory: "compatibility", bundle: bundle)
        let data = try Data(contentsOf: url)
        let parsed = try KDBXParser.parseWithMetaAndHeader(data: data, password: password, sessionKey: testSessionKey)

        XCTAssertEqual(parsed.header.formatVersion, .kdbx4(minor: 0), file: file, line: line)
        XCTAssertEqual(parsed.header.cipherID, expectedCipherUUID, file: file, line: line)

        let group = try XCTUnwrap(findGroup(named: "Foreign", in: parsed.rootGroup), file: file, line: line)
        let entriesByTitle = Dictionary(uniqueKeysWithValues: group.entries.map { ($0.title, $0) })

        let alpha = try XCTUnwrap(entriesByTitle["Foreign Entry Alpha"], file: file, line: line)
        XCTAssertEqual(alpha.username, "foreign-alpha-user", file: file, line: line)
        XCTAssertEqual(try alpha.password.decrypt(using: testSessionKey), "ForeignAlphaSecret1", file: file, line: line)
        XCTAssertEqual(alpha.customFields["ForeignField"], "ForeignFieldValue", file: file, line: line)

        let beta = try XCTUnwrap(entriesByTitle["Foreign Entry Beta"], file: file, line: line)
        XCTAssertEqual(beta.username, "foreign-beta-user", file: file, line: line)
        XCTAssertEqual(try beta.password.decrypt(using: testSessionKey), "ForeignBetaSecret2", file: file, line: line)
        XCTAssertTrue(beta.customFields.isEmpty, file: file, line: line)
    }

    // MARK: - Group Tags Fixture (KDBX 4.1)

    /// `compatibility/group-tags.kdbx` is authored by pykeepass (see
    /// `TestFixtures/compatibility/generate_group_tags_fixture.py`) as a real
    /// KDBX 4.1 file — the version that introduced group `<Tags>` — so this
    /// exercises the full decrypt path, not just the XML layer: header,
    /// version 4.1, KDF, outer cipher, and the group-tag parse on a database
    /// KeeForge did not write. pykeepass writes the tags `;`-separated
    /// (KeePass's canonical form), covering the semicolon split too.
    func testGroupTagsFixtureParsesGroupTagsThroughFullDecryptPath() throws {
        let bundle = Bundle(for: KDBXParserTests.self)
        let url = try TestDatabaseSupport.fixtureURL(named: "group-tags", subdirectory: "compatibility", bundle: bundle)
        let data = try Data(contentsOf: url)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data,
            password: "testpassword123",
            sessionKey: testSessionKey
        )

        XCTAssertEqual(parsed.header.formatVersion, .kdbx4(minor: 1))

        let projects = try XCTUnwrap(findGroup(named: "Projects", in: parsed.rootGroup))
        XCTAssertEqual(projects.tags, ["team", "shared"])
        XCTAssertTrue(projects.hasTagsElement)
        XCTAssertTrue(projects.hasNotesElement)
        XCTAssertEqual(
            projects.notes,
            "Group notes ride along as unknown XML next to the structured Tags element.",
            "The group's <Notes> parses into the structured field next to the structured <Tags>"
        )
        XCTAssertFalse(
            projects.unknownXML.nodes.contains { $0.xml.hasPrefix("<Notes>") },
            "Group <Notes> is structured now, so no opaque copy may remain"
        )
        let alpha = try XCTUnwrap(projects.entries.first { $0.title == "Alpha Login" })
        XCTAssertEqual(alpha.username, "alpha-user")
        XCTAssertEqual(try alpha.password.decrypt(using: testSessionKey), "GroupTagAlpha1")
        XCTAssertTrue(alpha.tags.isEmpty, "Group tags must not leak onto the parsed entry model")

        let clientWork = try XCTUnwrap(findGroup(named: "Client Work", in: parsed.rootGroup))
        XCTAssertEqual(clientWork.tags, ["billable"])
        XCTAssertTrue(clientWork.hasTagsElement)
        let beta = try XCTUnwrap(clientWork.entries.first { $0.title == "Beta Login" })
        XCTAssertEqual(beta.tags, ["own-tag"], "Entry tags parse independently of the enclosing group's")
        XCTAssertEqual(try beta.password.decrypt(using: testSessionKey), "GroupTagBeta2")

        let emptyTags = try XCTUnwrap(findGroup(named: "Empty Tags Group", in: parsed.rootGroup))
        XCTAssertTrue(emptyTags.hasTagsElement, "An empty <Tags/> element is present, just contentless")
        XCTAssertTrue(emptyTags.tags.isEmpty)

        let plain = try XCTUnwrap(findGroup(named: "Plain Group", in: parsed.rootGroup))
        XCTAssertFalse(plain.hasTagsElement, "No element in the source means none is tracked (or ever written)")
        XCTAssertTrue(plain.tags.isEmpty)
    }

    // MARK: - Unknown Inner-Header Fields Fixture

    /// `compatibility/unknown-inner-header.kdbx` carries three inner-header
    /// items whose type IDs KDBX4 does not define — including a zero-length
    /// one and one spliced between the two binary-pool entries (see
    /// `TestFixtures/compatibility/generate_unknown_inner_header_fixture.py`).
    /// Parsing must retain them in on-disk relative order and leave the entry,
    /// its protected password, and both attachments untouched.
    func testUnknownInnerHeaderFixtureRetainsUnknownFieldsWithoutDisturbingContent() throws {
        let bundle = Bundle(for: KDBXParserTests.self)
        let url = try TestDatabaseSupport.fixtureURL(
            named: "unknown-inner-header",
            subdirectory: "compatibility",
            bundle: bundle
        )
        let data = try Data(contentsOf: url)
        let parsed = try KDBXParser.parseWithMetaAndHeader(
            data: data,
            password: "unknown-inner-header",
            sessionKey: testSessionKey
        )

        XCTAssertEqual(
            parsed.header.unknownInnerHeaderFields,
            [
                KDBXParser.UnknownHeaderField(id: 0x21, data: Data("mid-pool-unknown-field".utf8)),
                KDBXParser.UnknownHeaderField(
                    id: 0x7F,
                    data: Data("kdbx-format-hardening-fixture:unknown-field-0x7f-marker".utf8)
                ),
                KDBXParser.UnknownHeaderField(id: 0x10, data: Data()),
            ]
        )

        let group = try XCTUnwrap(findGroup(named: "Unknown Header", in: parsed.rootGroup))
        let entry = try XCTUnwrap(group.entries.first { $0.title == "Inner Header Entry" })
        XCTAssertEqual(entry.username, "unknown-header-user")
        XCTAssertEqual(try entry.password.decrypt(using: testSessionKey), "UnknownHeaderSecret1")
        XCTAssertEqual(entry.url, "https://unknown-header.example.com")

        let pool = BinaryPool(rawFields: parsed.header.innerHeaderBinaryFields)
        XCTAssertEqual(pool.count, 2)
        var resolved: [String: Data] = [:]
        for attachment in entry.attachments {
            resolved[attachment.name] = try XCTUnwrap(pool[attachment.ref]?.data)
        }
        XCTAssertEqual(
            resolved,
            [
                "alpha-attachment.txt": Data("alpha attachment payload for unknown-inner-header fixture\n".utf8),
                "beta-attachment.txt": Data("beta attachment payload for unknown-inner-header fixture\n".utf8),
            ]
        )
    }

    // MARK: - Helpers

    private func parseFixture() throws -> KPGroup {
        let data = try fixtureData()
        return try KDBXParser.parse(data: data, password: fixturePassword, sessionKey: testSessionKey)
    }

    private func parseSingleEntry(fields: [String: String]) throws -> KPEntry {
        let strings = fields.map { key, value in
            "<String><Key>\(xmlEscape(key))</Key><Value>\(xmlEscape(value))</Value></String>"
        }.joined()
        let xml = "<KeePassFile><Root><Group><Name>Test</Name><Entry><String><Key>Title</Key><Value>OTP</Value></String>\(strings)</Entry></Group></Root></KeePassFile>"
        let parsed = try KDBXParser.parseXML(
            xmlData: Data(xml.utf8), innerStreamKey: Data(), innerStreamID: 0, sessionKey: testSessionKey
        )
        return try XCTUnwrap(parsed.rootGroup.allEntries.first)
    }

    private func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func referenceAESKDFTransform(compositeKey: Data, seed: Data, rounds: UInt64) throws -> Data {
        var left = compositeKey.prefix(16)
        var right = compositeKey.suffix(16)

        for _ in 0..<rounds {
            left = try referenceAESECBEncryptBlock(left, key: seed)
            right = try referenceAESECBEncryptBlock(right, key: seed)
        }

        return KDBXCrypto.sha256(Data(left + right))
    }

    private func referenceAESECBEncryptBlock(_ block: some DataProtocol, key: some DataProtocol) throws -> Data {
        let blockData = Data(block)
        let keyData = Data(key)
        guard blockData.count == kCCBlockSizeAES128, keyData.count == kCCKeySizeAES256 else {
            throw KDBXCrypto.CryptoError.invalidKey
        }

        var outData = Data(count: kCCBlockSizeAES128)
        let outLength = outData.count
        var bytesWritten = 0

        let status = outData.withUnsafeMutableBytes { outPtr in
            blockData.withUnsafeBytes { dataPtr in
                keyData.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress,
                        keyData.count,
                        nil,
                        dataPtr.baseAddress,
                        blockData.count,
                        outPtr.baseAddress,
                        outLength,
                        &bytesWritten
                    )
                }
            }
        }

        guard status == kCCSuccess, bytesWritten == kCCBlockSizeAES128 else {
            throw KDBXCrypto.CryptoError.encryptionFailed
        }

        return outData
    }

    private func fixtureData() throws -> Data {
        let bundle = Bundle(for: KDBXParserTests.self)
        let fixtureURL = try XCTUnwrap(bundle.url(forResource: "test", withExtension: "kdbx"))
        return try Data(contentsOf: fixtureURL)
    }

    private struct Salsa20Vector {
        let key: String
        let plaintext: String
        let base64Ciphertext: String
    }

    /// Arbitrary 32-byte inner stream key (0x00…0x1F) the pinned vectors were
    /// generated against.
    private static let salsa20InnerStreamKey = Data((0..<32).map { UInt8($0) })

    private static let salsa20Vectors: [Salsa20Vector] = [
        Salsa20Vector(
            key: "A",
            plaintext: String(repeating: "a", count: 63),
            base64Ciphertext: "mN/USAPi601d40avjPHzEkYQ9p7OhwyFOP4rt0zH/Xx8RBAXjuXeUSIcbmZMfNBTpmuQ3uINrWl4ecNXeC3H"
        ),
        Salsa20Vector(key: "B", plaintext: "b", base64Ciphertext: "zA=="),
        Salsa20Vector(
            key: "C",
            plaintext: String(repeating: "c", count: 64),
            base64Ciphertext: "3QqhioUCk/I8eql9YPJfFzlw4rwoueCjLT+e4DjR7uObFnrZeO7e14syNs+gGfcH7jkyBD/+jeRQDvx5ek403Q=="
        ),
        Salsa20Vector(
            key: "D",
            plaintext: String(repeating: "d", count: 65),
            base64Ciphertext: "bMkURHZTNLl+0DOiMl+ok4NXniBQD2rqA8aMbPBH51Ejz7wdbkkpO7R40Ry28bLfQBiOhvoOYleruVEE4ikdj/Y="
        ),
        Salsa20Vector(
            key: "E",
            plaintext: String(repeating: "e", count: 200),
            base64Ciphertext: "v82SKcZyj37ShRF/Gl3YifI4I3ChtspgQ5O3C7F37YXgfoNHepq+McfTRuX3whYTxGcd1pb9as7uiFzs" +
                "cP/GotoWwl+9x7vLyqM4rByxH5/GLsJUvhJ1P1YMC8YqJWv7jZXL0qTQMhpPVlMy84u80xU1Ulzm6Q63jAqVLFasZKq6" +
                "7vej4r5yGSF4E4NHdZZAGkC7GGz5JrFD8PRNEpzKtZK9bDfVuVezFf4C+QFFTrDoZpxgs97+/2qoVp6V8+mpqDl6FkTH" +
                "NeU="
        ),
    ]

    private func parseSalsa20ProtectedValues(interleavingEmptyValues: Bool) throws -> KPEntry {
        var strings = ""
        for (index, vector) in Self.salsa20Vectors.enumerated() {
            if interleavingEmptyValues {
                strings += "<String><Key>Empty\(index)</Key><Value Protected=\"True\"></Value></String>"
            }
            strings += "<String><Key>\(vector.key)</Key>"
            strings += "<Value Protected=\"True\">\(vector.base64Ciphertext)</Value></String>"
        }

        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<KeePassFile><Meta></Meta><Root><Group>"
            + "<UUID>\(Data(repeating: 0x11, count: 16).base64EncodedString())</UUID><Name>Salsa20</Name>"
            + "<Entry><UUID>\(Data(repeating: 0x22, count: 16).base64EncodedString())</UUID>"
            + strings
            + "</Entry></Group></Root></KeePassFile>"

        let parsed = try KDBXXMLParser(
            data: Data(xml.utf8),
            innerStreamKey: Self.salsa20InnerStreamKey,
            innerStreamID: KDBXParser.innerStreamSalsa20,
            sessionKey: testSessionKey
        ).parse()

        return try XCTUnwrap(parsed.rootGroup.allEntries.first)
    }

    private func legacyFixtureData() throws -> Data {
        let bundle = Bundle(for: KDBXParserTests.self)
        let fixtureURL = try XCTUnwrap(bundle.url(forResource: "test-v3-backup", withExtension: "kdbx"))
        return try Data(contentsOf: fixtureURL)
    }

    private func makeLegacyFixtureWithCorruptedHashedBlock() throws -> Data {
        let data = try legacyFixtureData()
        let legacyHeader = try KDBXParser.parseKDBX3Header(from: data)
        let compositeKey = KDBXCrypto.compositeKey(password: legacyFixturePassword)
        let masterKey = try KDBXParser.deriveKDBX3MasterKey(
            compositeKey: compositeKey,
            header: legacyHeader
        )
        let encryptedPayload = data.subdata(in: legacyHeader.payloadOffset..<data.count)
        var decryptedPayload = try KDBXCrypto.decryptAES256CBC(
            data: encryptedPayload,
            key: masterKey,
            iv: legacyHeader.encryptionIV
        )

        let firstBlockDataOffset = legacyHeader.streamStartBytes.count + 4 + 32 + 4
        XCTAssertLessThan(firstBlockDataOffset, decryptedPayload.count)
        decryptedPayload[firstBlockDataOffset] ^= 0x01

        let reencryptedPayload = try KDBXCrypto.encryptAES256CBC(
            data: decryptedPayload,
            key: masterKey,
            iv: legacyHeader.encryptionIV
        )

        var mutated = Data(data.prefix(legacyHeader.payloadOffset))
        mutated.append(reencryptedPayload)
        return mutated
    }

    private func makeLegacyTwofishFixture() throws -> Data {
        let data = try legacyFixtureData()
        let legacyHeader = try KDBXParser.parseKDBX3Header(from: data)
        let compositeKey = KDBXCrypto.compositeKey(password: legacyFixturePassword)
        let masterKey = try KDBXParser.deriveKDBX3MasterKey(
            compositeKey: compositeKey,
            header: legacyHeader
        )
        let encryptedPayload = data.subdata(in: legacyHeader.payloadOffset..<data.count)
        let decryptedPayload = try KDBXCrypto.decryptAES256CBC(
            data: encryptedPayload,
            key: masterKey,
            iv: legacyHeader.encryptionIV
        )
        let twofishPayload = try KDBXCrypto.encryptTwofish256CBC(
            data: decryptedPayload,
            key: masterKey,
            iv: legacyHeader.encryptionIV
        )

        let cipherOffset = try XCTUnwrap(legacyHeaderFieldValueOffset(fieldID: 2, in: data))
        var convertedHeader = Data(data.prefix(legacyHeader.payloadOffset))
        convertedHeader.replaceSubrange(
            cipherOffset..<(cipherOffset + KDBXParser.twofishCipherUUID.count),
            with: KDBXParser.twofishCipherUUID
        )
        convertedHeader.append(twofishPayload)
        return convertedHeader
    }

    private func legacyHeaderFieldValueOffset(fieldID: UInt8, in data: Data) -> Int? {
        var offset = 12
        while offset + 3 <= data.count {
            let currentFieldID = data[offset]
            let fieldSize = data[(offset + 1)..<(offset + 3)].withUnsafeBytes {
                $0.loadUnaligned(as: UInt16.self).littleEndian
            }
            if currentFieldID == fieldID {
                return offset + 3
            }
            offset += 3 + Int(fieldSize)
            if currentFieldID == 0 {
                return nil
            }
        }
        return nil
    }

    private func allGroupNames(in root: KPGroup) -> [String] {
        root.groups.flatMap { group in
            [group.name] + allGroupNames(in: group)
        }
    }

    private func findGroup(named name: String, in root: KPGroup) -> KPGroup? {
        for group in root.groups {
            if group.name == name { return group }
            if let found = findGroup(named: name, in: group) { return found }
        }
        return nil
    }

    // MARK: - Security: Truncated / Malformed File Tests

    func testEmptyDataThrowsTruncated() {
        XCTAssertThrowsError(
            try KDBXParser.parse(data: Data(), password: "x", sessionKey: testSessionKey)
        ) { error in
            XCTAssertEqual(error as? KDBXParser.ParseError, .truncatedFile)
        }
    }

    func testTruncatedSignatureThrows() {
        // Only 6 bytes — not enough for two UInt32 signatures
        let data = Data([0x03, 0xD9, 0xA2, 0x9A, 0x67, 0xFB])
        XCTAssertThrowsError(
            try KDBXParser.parse(data: data, password: "x", sessionKey: testSessionKey)
        ) { error in
            XCTAssertEqual(error as? KDBXParser.ParseError, .truncatedFile)
        }
    }

    func testInvalidSignatureThrows() {
        // 12 bytes: wrong sig1, correct sig2, version 4
        var data = Data()
        data.appendLE(UInt32(0xDEADBEEF))
        data.appendLE(UInt32(0xB54BFB67))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(4))
        XCTAssertThrowsError(
            try KDBXParser.parse(data: data, password: "x", sessionKey: testSessionKey)
        ) { error in
            XCTAssertEqual(error as? KDBXParser.ParseError, .invalidSignature)
        }
    }

    func testTruncatedAfterVersionThrows() {
        // Valid signatures + version, but no header fields
        var data = Data()
        data.appendLE(UInt32(0x9AA2D903))
        data.appendLE(UInt32(0xB54BFB67))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(4))
        // No header data follows — parser should throw truncatedFile
        XCTAssertThrowsError(
            try KDBXParser.parse(data: data, password: "x", sessionKey: testSessionKey)
        ) { error in
            // The header parsing loop sees hasMore=false, returns empty header,
            // then readBytes(32) for storedHeaderSHA fails
            XCTAssertEqual(error as? KDBXParser.ParseError, .truncatedFile)
        }
    }

    func testTruncatedHeaderFieldThrows() {
        // Valid preamble, then a header field that claims 100 bytes but file ends
        var data = Data()
        data.appendLE(UInt32(0x9AA2D903))
        data.appendLE(UInt32(0xB54BFB67))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(4))
        data.append(2) // field ID = cipherID
        data.appendLE(UInt32(100)) // claims 100 bytes
        data.append(Data(repeating: 0, count: 10)) // only 10 bytes
        XCTAssertThrowsError(
            try KDBXParser.parse(data: data, password: "x", sessionKey: testSessionKey)
        ) { error in
            XCTAssertEqual(error as? KDBXParser.ParseError, .truncatedFile)
        }
    }

    // MARK: - Security: Argon2 Parameter Bounds Tests

    func testArgon2ExcessiveIterationsRejected() {
        // 64 MiB × 2000 iterations = 125 GiB of total work — over the 64 GiB main-app budget
        let data = buildKDBXWithKDFParams(iterations: 2_000, memory: 64 * 1024 * 1024, parallelism: 1)
        XCTAssertThrowsError(
            try KDBXParser.parse(data: data, password: "x", sessionKey: testSessionKey)
        ) { error in
            guard case KDBXParser.ParseError.kdfResourceLimitExceeded = error else {
                XCTFail("Expected kdfResourceLimitExceeded, got \(error)")
                return
            }
        }
    }

    func testArgon2ZeroIterationsRejected() {
        let data = buildKDBXWithKDFParams(iterations: 0, memory: 64 * 1024 * 1024, parallelism: 1)
        XCTAssertThrowsError(
            try KDBXParser.parse(data: data, password: "x", sessionKey: testSessionKey)
        ) { error in
            guard case KDBXParser.ParseError.kdfParameterOutOfRange(let msg) = error else {
                XCTFail("Expected kdfParameterOutOfRange, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("iterations"))
        }
    }

    func testArgon2ExcessiveMemoryRejected() {
        // 8 GiB — way over the 4 GiB peak-memory budget
        let data = buildKDBXWithKDFParams(iterations: 3, memory: 8_589_934_592, parallelism: 1)
        XCTAssertThrowsError(
            try KDBXParser.parse(data: data, password: "x", sessionKey: testSessionKey)
        ) { error in
            guard case KDBXParser.ParseError.kdfResourceLimitExceeded = error else {
                XCTFail("Expected kdfResourceLimitExceeded, got \(error)")
                return
            }
        }
    }

    func testArgon2TooSmallMemoryRejected() {
        // 1 KB — under 8 KB minimum
        let data = buildKDBXWithKDFParams(iterations: 3, memory: 1024, parallelism: 1)
        XCTAssertThrowsError(
            try KDBXParser.parse(data: data, password: "x", sessionKey: testSessionKey)
        ) { error in
            guard case KDBXParser.ParseError.kdfParameterOutOfRange(let msg) = error else {
                XCTFail("Expected kdfParameterOutOfRange, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("memory"))
        }
    }

    func testArgon2ExcessiveParallelismRejected() {
        // 257 lanes is valid per spec (64 MiB covers the 8 KiB-per-lane minimum) but over the 256-lane budget
        let data = buildKDBXWithKDFParams(iterations: 3, memory: 64 * 1024 * 1024, parallelism: 257)
        XCTAssertThrowsError(
            try KDBXParser.parse(data: data, password: "x", sessionKey: testSessionKey)
        ) { error in
            guard case KDBXParser.ParseError.kdfResourceLimitExceeded = error else {
                XCTFail("Expected kdfResourceLimitExceeded, got \(error)")
                return
            }
        }
    }

    func testArgon2HighParallelismAccepted() throws {
        // 64 threads — valid for modern machines. Exercise KDBXParser.deriveKey
        // directly (the actual unit under range-validation) so the test can
        // assert the positive outcome — a real 32-byte derived key — instead
        // of only checking that a specific error wasn't thrown.
        let params: [String: Any] = [
            "$UUID": KDBXParser.argon2idUUID,
            "I": UInt64(2),
            "M": UInt64(64 * 1024 * 1024),
            "P": UInt32(64),
            "V": UInt32(0x13),
            "S": Data((0..<32).map { UInt8($0) }),
        ]

        let derivedKey = try KDBXParser.deriveKey(compositeKey: Data("composite-key".utf8), kdfParams: params)

        XCTAssertEqual(derivedKey.count, 32)
    }

    func testArgon2ZeroParallelismRejected() {
        let data = buildKDBXWithKDFParams(iterations: 3, memory: 64 * 1024 * 1024, parallelism: 0)
        XCTAssertThrowsError(
            try KDBXParser.parse(data: data, password: "x", sessionKey: testSessionKey)
        ) { error in
            guard case KDBXParser.ParseError.kdfParameterOutOfRange(let msg) = error else {
                XCTFail("Expected kdfParameterOutOfRange, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("parallelism"))
        }
    }

    // MARK: - KDF Test Helpers

    /// Build minimal KDBX data with valid signatures, version, header (including KDF params),
    /// and correct header SHA-256 so the parser reaches deriveKey() where bounds are checked.
    private func buildKDBXWithKDFParams(iterations: UInt64, memory: UInt64, parallelism: UInt32) -> Data {
        var header = Data()

        // Signatures + version
        header.appendLE(UInt32(0x9AA2D903))
        header.appendLE(UInt32(0xB54BFB67))
        header.appendLE(UInt16(1)) // minor
        header.appendLE(UInt16(4)) // major

        // CipherID field (field 2) — ChaCha20
        header.append(2) // field ID
        header.appendLE(UInt32(16)) // size
        header.append(Data([0xD6, 0x03, 0x8A, 0x2B, 0x8B, 0x6F, 0x4C, 0xB5,
                            0xA5, 0x24, 0x33, 0x9A, 0x31, 0xDB, 0xB5, 0x9A]))

        // CompressionFlags field (field 3) — no compression
        header.append(3)
        header.appendLE(UInt32(4))
        header.appendLE(UInt32(0))

        // MasterSeed field (field 4) — 32 random bytes
        header.append(4)
        header.appendLE(UInt32(32))
        header.append(Data(repeating: 0xAA, count: 32))

        // EncryptionIV field (field 7) — 12 bytes for ChaCha20
        header.append(7)
        header.appendLE(UInt32(12))
        header.append(Data(repeating: 0xBB, count: 12))

        // KDF Parameters field (field 11)
        let kdfData = buildArgon2VariantMap(
            uuid: KDBXParser.argon2dUUID,
            iterations: iterations,
            memory: memory,
            parallelism: parallelism
        )
        header.append(11)
        header.appendLE(UInt32(kdfData.count))
        header.append(kdfData)

        // End of header (field 0)
        header.append(0)
        header.appendLE(UInt32(0))

        // Compute header SHA-256 and append it + dummy HMAC
        let sha = KDBXCrypto.sha256(header)
        var result = header
        result.append(sha)
        result.append(Data(repeating: 0, count: 32)) // dummy HMAC (won't be reached)

        return result
    }

    private func buildArgon2VariantMap(
        uuid: Data,
        iterations: UInt64,
        memory: UInt64,
        parallelism: UInt32
    ) -> Data {
        var map = Data()
        map.appendLE(UInt16(0x0100)) // version

        appendVariantEntry(&map, type: 0x42, key: "$UUID", value: uuid)

        // S (salt) — byte array
        appendVariantEntry(&map, type: 0x42, key: "S", value: Data(repeating: 0xCC, count: 32))

        // I (iterations) — UInt64
        var iterBytes = Data(count: 8)
        iterBytes.withUnsafeMutableBytes { $0.storeBytes(of: iterations.littleEndian, as: UInt64.self) }
        appendVariantEntry(&map, type: 0x05, key: "I", value: iterBytes)

        // M (memory) — UInt64
        var memBytes = Data(count: 8)
        memBytes.withUnsafeMutableBytes { $0.storeBytes(of: memory.littleEndian, as: UInt64.self) }
        appendVariantEntry(&map, type: 0x05, key: "M", value: memBytes)

        // P (parallelism) — UInt32
        var parBytes = Data(count: 4)
        parBytes.withUnsafeMutableBytes { $0.storeBytes(of: parallelism.littleEndian, as: UInt32.self) }
        appendVariantEntry(&map, type: 0x04, key: "P", value: parBytes)

        // Terminator
        map.append(0x00)

        return map
    }

    private func buildAESVariantMap(rounds: UInt64) -> Data {
        var map = Data()
        map.appendLE(UInt16(0x0100))

        appendVariantEntry(&map, type: 0x42, key: "$UUID",
                           value: Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60,
                                        0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA]))
        appendVariantEntry(&map, type: 0x42, key: "S", value: Data((32..<64).map(UInt8.init)))

        var roundBytes = Data(count: 8)
        roundBytes.withUnsafeMutableBytes { $0.storeBytes(of: rounds.littleEndian, as: UInt64.self) }
        appendVariantEntry(&map, type: 0x05, key: "R", value: roundBytes)

        map.append(0x00)
        return map
    }

    func testAESVariantMapDerivesKey() throws {
        let compositeKey = Data((0..<32).map(UInt8.init))
        let params: [String: Any] = [
            "$UUID": Data([0xC9, 0xD9, 0xF3, 0x9A, 0x62, 0x8A, 0x44, 0x60,
                            0xBF, 0x74, 0x0D, 0x08, 0xC1, 0x8A, 0x4F, 0xEA]),
            "S": Data((32..<64).map(UInt8.init)),
            "R": UInt64(10),
        ]
        let derived = try KDBXParser.deriveKey(compositeKey: compositeKey, kdfParams: params)

        XCTAssertEqual(
            derived.hexString,
            "f76f387e7538424a09d988e6f358824cd30d0dd35d0e8ecb1487ff6ffc1581cf"
        )
    }

    func testAESVariantMapRejectsRoundsAboveUpdatedMaximum() {
        let compositeKey = Data((0..<32).map(UInt8.init))
        let params: [String: Any] = [
            "$UUID": KDBXParser.aesKDFUUID,
            "S": Data((32..<64).map(UInt8.init)),
            "R": KDBXParser.aesKDFMaxRounds + 1,
        ]

        XCTAssertThrowsError(
            try KDBXParser.deriveKey(compositeKey: compositeKey, kdfParams: params)
        ) { error in
            guard case KDBXParser.ParseError.kdfParameterOutOfRange(let message) = error else {
                XCTFail("Expected kdfParameterOutOfRange, got \(error)")
                return
            }
            XCTAssertEqual(
                message,
                "rounds \(KDBXParser.aesKDFMaxRounds + 1) not in 1...\(KDBXParser.aesKDFMaxRounds)"
            )
        }
    }

    func testLegacyHeaderRejectsRoundsAboveUpdatedMaximum() {
        let compositeKey = Data(repeating: 0x11, count: 32)
        let header = KDBXParser.LegacyHeader(
            formatVersion: .kdbx3_1,
            cipherID: Data(),
            compressionFlags: 0,
            masterSeed: Data(repeating: 0x22, count: 32),
            transformSeed: Data(repeating: 0x33, count: 32),
            transformRounds: KDBXParser.aesKDFMaxRounds + 1,
            encryptionIV: Data(),
            protectedStreamKey: Data(),
            streamStartBytes: Data(),
            innerRandomStreamID: 0,
            headerData: Data(),
            payloadOffset: 0
        )

        XCTAssertThrowsError(
            try KDBXParser.deriveKDBX3MasterKey(compositeKey: compositeKey, header: header)
        ) { error in
            guard case KDBXParser.ParseError.kdfParameterOutOfRange(let message) = error else {
                XCTFail("Expected kdfParameterOutOfRange, got \(error)")
                return
            }
            XCTAssertEqual(
                message,
                "rounds \(KDBXParser.aesKDFMaxRounds + 1) not in 1...\(KDBXParser.aesKDFMaxRounds)"
            )
        }
    }

    func testArgon2idVariantMapDerivesKey() throws {
        let compositeKey = Data((0..<32).map(UInt8.init))
        let salt = Data(repeating: 0xCC, count: 32)
        let params: [String: Any] = [
            "$UUID": KDBXParser.argon2idUUID,
            "S": salt,
            "I": UInt64(3),
            "M": UInt64(64 * 1024 * 1024),
            "P": UInt32(1),
        ]

        let derived = try KDBXParser.deriveKey(compositeKey: compositeKey, kdfParams: params)
        let expected = try Argon2.hash(
            password: compositeKey,
            salt: salt,
            timeCost: 3,
            memoryCost: 64 * 1024,
            parallelism: 1,
            hashLength: 32,
            version: .v13,
            variant: .id
        )
        let argon2d = try Argon2.hash(
            password: compositeKey,
            salt: salt,
            timeCost: 3,
            memoryCost: 64 * 1024,
            parallelism: 1,
            hashLength: 32,
            version: .v13,
            variant: .d
        )

        XCTAssertEqual(derived, expected)
        XCTAssertNotEqual(derived, argon2d)
    }

    private func appendVariantEntry(_ data: inout Data, type: UInt8, key: String, value: Data) {
        data.append(type)
        let keyData = Data(key.utf8)
        data.appendLE(UInt32(keyData.count))
        data.append(keyData)
        data.appendLE(UInt32(value.count))
        data.append(value)
    }
}

// MARK: - Test Data Helpers

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }

    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
}
