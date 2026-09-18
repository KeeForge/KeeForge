import XCTest
@testable import KeeForge

final class FTPListingParserTests: XCTestCase {
    // MARK: - MLSD / MLST

    func testMachineEntryParsesFactsCaseInsensitivelyAndKeepsSpacesInName() {
        let entry = FTPListingParser.parseMachineEntry("Type=file;Size=2048;Modify=20260918120001.250;Perm=adfrw; My Vault.kdbx")

        XCTAssertEqual(entry, FTPListEntry(name: "My Vault.kdbx", isFolder: false, size: 2048, modifiedStamp: "20260918120001.250"))
    }

    func testMachineEntrySkipsCurrentAndParentDirectories() {
        XCTAssertNil(FTPListingParser.parseMachineEntry("type=cdir;modify=20260101000000; ."))
        XCTAssertNil(FTPListingParser.parseMachineEntry("type=pdir;modify=20260101000000; .."))
    }

    func testMachineEntryReducesMLSTPathnameToItsLastComponent() {
        let entry = FTPListingParser.parseMachineEntry(" type=file;size=5;modify=20260918120001; /vaults/personal.kdbx")

        XCTAssertEqual(entry?.name, "personal.kdbx")
    }

    func testMachineEntryIgnoresMalformedModifyStamp() {
        let entry = FTPListingParser.parseMachineEntry("type=file;size=5;modify=yesterday; a.kdbx")

        XCTAssertNil(entry?.modifiedStamp)
    }

    func testMachineEntryRejectsLinesWithoutType() {
        XCTAssertNil(FTPListingParser.parseMachineEntry("End"))
        XCTAssertNil(FTPListingParser.parseMachineEntry("size=5; a.kdbx"))
    }

    // MARK: - LIST

    func testUnixListLineWithOwnerAndGroup() {
        let entry = FTPListingParser.parseListLine("-rw-r--r--    1 alex     staff        3072 Sep 18 12:00 personal vault.kdbx")

        XCTAssertEqual(entry, FTPListEntry(name: "personal vault.kdbx", isFolder: false, size: 3072, modifiedStamp: nil))
    }

    func testUnixListLineWithoutGroupAndWithYear() {
        let entry = FTPListingParser.parseListLine("-rw-r--r-- 1 alex 3072 Jan  3  2025 old.kdbx")

        XCTAssertEqual(entry?.name, "old.kdbx")
        XCTAssertEqual(entry?.size, 3072)
    }

    func testUnixListDirectoryAndSymlink() {
        XCTAssertEqual(
            FTPListingParser.parseListLine("drwxr-xr-x 2 alex staff 4096 Jan 01 12:00 Vaults"),
            FTPListEntry(name: "Vaults", isFolder: true, size: nil, modifiedStamp: nil)
        )
        XCTAssertEqual(
            FTPListingParser.parseListLine("lrwxrwxrwx 1 alex staff 12 Jan 01 12:00 current.kdbx -> v2.kdbx")?.name,
            "current.kdbx"
        )
    }

    func testDOSListLines() {
        XCTAssertEqual(
            FTPListingParser.parseListLine("09-18-26  12:00PM       <DIR>          Vaults"),
            FTPListEntry(name: "Vaults", isFolder: true, size: nil, modifiedStamp: nil)
        )
        XCTAssertEqual(
            FTPListingParser.parseListLine("09-18-26  12:00PM                 3072 work vault.kdbx"),
            FTPListEntry(name: "work vault.kdbx", isFolder: false, size: 3072, modifiedStamp: nil)
        )
    }

    func testListSkipsSummaryAndDotEntries() {
        XCTAssertNil(FTPListingParser.parseListLine("total 12"))
        XCTAssertNil(FTPListingParser.parseListLine("drwxr-xr-x 2 alex staff 4096 Jan 01 12:00 ."))
        XCTAssertNil(FTPListingParser.parseListLine("drwxr-xr-x 2 alex staff 4096 Jan 01 12:00 .."))
    }

    // MARK: - Timestamps

    func testTimeValParsesAsUTCWithFraction() throws {
        let date = try XCTUnwrap(FTPListingParser.date(fromTimeVal: "20260918120001.5"))

        XCTAssertEqual(date.timeIntervalSince1970, 1_789_732_801.5, accuracy: 0.001)
    }

    func testTimeValRejectsWrongLengthAndInvalidDates() {
        XCTAssertNil(FTPListingParser.date(fromTimeVal: "202609181200"))
        XCTAssertNil(FTPListingParser.date(fromTimeVal: "20261318120000"))
        XCTAssertNil(FTPListingParser.date(fromTimeVal: "2026091812000a"))
        XCTAssertNil(FTPListingParser.date(fromTimeVal: "20260918120000."))
    }

    // MARK: - Passive replies

    func testExtendedPassivePortReadsServerChosenDelimiter() {
        XCTAssertEqual(FTPListingParser.extendedPassivePort(from: "Entering Extended Passive Mode (|||6446|)"), 6446)
        XCTAssertEqual(FTPListingParser.extendedPassivePort(from: "Entering Extended Passive Mode (!!!2121!)"), 2121)
        XCTAssertNil(FTPListingParser.extendedPassivePort(from: "Entering Extended Passive Mode"))
        XCTAssertNil(FTPListingParser.extendedPassivePort(from: "Entering Extended Passive Mode (|||0|)"))
    }

    func testPassivePortWithAndWithoutParentheses() {
        XCTAssertEqual(FTPListingParser.passivePort(from: "Entering Passive Mode (192,168,1,20,19,137)."), 19 * 256 + 137)
        XCTAssertEqual(FTPListingParser.passivePort(from: "Entering Passive Mode 192,168,1,20,4,1"), 4 * 256 + 1)
        XCTAssertNil(FTPListingParser.passivePort(from: "Entering Passive Mode (192,168,1,20,300,1)"))
        XCTAssertNil(FTPListingParser.passivePort(from: "Entering Passive Mode"))
    }
}

final class FTPURLTests: XCTestCase {
    func testNormalizationAddsSchemeLowercasesHostAndEndsInOneSlash() throws {
        let url = try FTPURL.normalizedBaseURL(from: "  NAS.local/Vaults//  ", allowsUnencryptedFTP: true)

        XCTAssertEqual(url.absoluteString, "ftp://nas.local/Vaults/")
    }

    func testNormalizationDropsDefaultPortAndCredentialsButKeepsCustomPort() throws {
        XCTAssertEqual(
            try FTPURL.normalizedBaseURL(from: "ftp://user:pw@nas.local:21/", allowsUnencryptedFTP: true).absoluteString,
            "ftp://nas.local/"
        )
        XCTAssertEqual(
            try FTPURL.normalizedBaseURL(from: "ftp://nas.local:2121", allowsUnencryptedFTP: true).absoluteString,
            "ftp://nas.local:2121/"
        )
    }

    func testNormalizationRequiresTheUnencryptedOptIn() {
        XCTAssertThrowsError(try FTPURL.normalizedBaseURL(from: "ftp://nas.local/", allowsUnencryptedFTP: false)) { error in
            XCTAssertEqual(error as? FTPURLError, .unencryptedNotAllowed)
        }
    }

    func testNormalizationRejectsOtherSchemes() {
        for address in ["sftp://nas.local/", "ftps://nas.local/", "https://nas.local/"] {
            XCTAssertThrowsError(try FTPURL.normalizedBaseURL(from: address, allowsUnencryptedFTP: true)) { error in
                XCTAssertEqual(error as? FTPURLError, .unsupportedScheme, address)
            }
        }
    }

    func testLocationTreatsPathAsRelativeToLoginDirectory() throws {
        let root = try XCTUnwrap(FTPURL.location(fromNormalizedBaseURL: XCTUnwrap(URL(string: "ftp://nas.local/"))))
        XCTAssertEqual(root, FTPServerLocation(host: "nas.local", port: 21, basePath: ""))

        let nested = try XCTUnwrap(FTPURL.location(fromNormalizedBaseURL: XCTUnwrap(URL(string: "ftp://nas.local:2121/My%20Vaults/sub/"))))
        XCTAssertEqual(nested, FTPServerLocation(host: "nas.local", port: 2121, basePath: "My Vaults/sub"))

        let absolute = try XCTUnwrap(FTPURL.location(fromNormalizedBaseURL: XCTUnwrap(URL(string: "ftp://nas.local/%2Fsrv/ftp/"))))
        XCTAssertEqual(absolute.basePath, "/srv/ftp")

        let ipv6 = try XCTUnwrap(FTPURL.location(fromNormalizedBaseURL: FTPURL.normalizedBaseURL(from: "ftp://[FE80::1]:2121/", allowsUnencryptedFTP: true)))
        XCTAssertEqual(ipv6, FTPServerLocation(host: "fe80::1", port: 2121, basePath: ""))
    }

    func testRemotePathJoinsBaseAndFileId() {
        XCTAssertEqual(FTPCloudProvider.remotePath(base: "", fileId: "/"), "")
        XCTAssertEqual(FTPCloudProvider.remotePath(base: "", fileId: "/a.kdbx"), "a.kdbx")
        XCTAssertEqual(FTPCloudProvider.remotePath(base: "vaults", fileId: "/"), "vaults")
        XCTAssertEqual(FTPCloudProvider.remotePath(base: "vaults", fileId: "/sub/a.kdbx"), "vaults/sub/a.kdbx")
        XCTAssertEqual(FTPCloudProvider.remotePath(base: "/", fileId: "/a.kdbx"), "/a.kdbx")
    }

    func testAccountIdIsStableSecretFreeAndDistinctPerUser() throws {
        let base = try XCTUnwrap(URL(string: "ftp://nas.local/"))
        let first = FTPURL.accountId(normalizedBaseURL: base, username: "alex")

        XCTAssertTrue(first.hasPrefix("ftp-"))
        XCTAssertEqual(first.count, 36)
        XCTAssertEqual(first, FTPURL.accountId(normalizedBaseURL: base, username: "alex"))
        XCTAssertNotEqual(first, FTPURL.accountId(normalizedBaseURL: base, username: "sam"))
    }

    func testDisplayNameShowsNonDefaultPortAndPath() throws {
        XCTAssertEqual(
            FTPURL.displayName(normalizedBaseURL: try XCTUnwrap(URL(string: "ftp://nas.local:2121/vaults/")), username: "alex"),
            "alex@nas.local:2121/vaults"
        )
        XCTAssertEqual(
            FTPURL.displayName(normalizedBaseURL: try XCTUnwrap(URL(string: "ftp://nas.local/")), username: "alex"),
            "alex@nas.local"
        )
    }
}
