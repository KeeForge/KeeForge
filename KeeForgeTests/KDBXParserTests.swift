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
        let nestedEntry = root.allEntries.first { $0.title == "日本語テスト 🔑" }
        XCTAssertNotNil(nestedEntry, "Entry in nested group not found via allEntries")
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

    func testKP2AURLFieldsExcludedFromCustomFields() throws {
        let root = try parseFixture()
        let github = try XCTUnwrap(root.allEntries.first { $0.title == "GitHub" })

        let kp2aKeys = github.customFields.keys.filter { $0.hasPrefix("KP2A_URL_") }
        // KP2A_URL fields should still be in customFields (additionalURLs reads from them)
        XCTAssertEqual(kp2aKeys.count, 2)
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

    func testKDBX31WrongPasswordFailsCleanly() throws {
        let data = try legacyFixtureData()

        XCTAssertThrowsError(
            try KDBXParser.parse(data: data, password: "definitely-wrong", sessionKey: testSessionKey)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains("wrong password"),
                "Expected a friendly wrong-password failure, got: \(error.localizedDescription)"
            )
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
                "This database uses an unsupported protected-field stream."
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

        XCTAssertEqual(error.errorDescription, "Unsupported key derivation function: AES-KDF")
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

    // MARK: - Helpers

    private func parseFixture() throws -> KPGroup {
        let data = try fixtureData()
        return try KDBXParser.parse(data: data, password: fixturePassword, sessionKey: testSessionKey)
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
        let data = buildKDBXWithKDFParams(iterations: 1_001, memory: 64 * 1024 * 1024, parallelism: 1)
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
        // 8GB — way over the 4GB limit
        let data = buildKDBXWithKDFParams(iterations: 3, memory: 8_589_934_592, parallelism: 1)
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
        let data = buildKDBXWithKDFParams(iterations: 3, memory: 64 * 1024 * 1024, parallelism: 257)
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

    func testArgon2HighParallelismAccepted() {
        // 64 threads — valid for modern machines, should not throw kdfParameterOutOfRange
        let data = buildKDBXWithKDFParams(iterations: 3, memory: 64 * 1024 * 1024, parallelism: 64)
        // This will fail later in parsing (bad decrypt etc.) but must NOT fail with kdfParameterOutOfRange
        do {
            _ = try KDBXParser.parse(data: data, password: "x", sessionKey: testSessionKey)
            XCTFail("Expected some parse error (bad data), but succeeded unexpectedly")
        } catch KDBXParser.ParseError.kdfParameterOutOfRange {
            XCTFail("parallelism=64 should be accepted, not rejected as out of range")
        } catch {
            // Any other error is fine — we just care that it's not kdfParameterOutOfRange
        }
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
            variant: .id
        )
        let argon2d = try Argon2.hash(
            password: compositeKey,
            salt: salt,
            timeCost: 3,
            memoryCost: 64 * 1024,
            parallelism: 1,
            hashLength: 32,
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
