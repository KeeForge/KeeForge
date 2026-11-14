import Foundation
import XCTest
@testable import KeeForge

enum TestDatabaseSupport {
    final class LocalPublicationTrace: @unchecked Sendable {
        private let lock = NSLock()
        private var observations: [String] = []
        func record(_ phase: String, _ error: Error) {
            let value = Self.describe(error, phase: phase)
            lock.lock(); defer { lock.unlock() }
            observations.append(value)
        }
        func recordObservation(_ observation: String) {
            lock.lock(); defer { lock.unlock() }
            observations.append(observation)
        }
        var summary: String { lock.lock(); defer { lock.unlock() }; return observations.joined(separator: ",") }
        func failure(_ error: Error, at phase: String) -> String {
            let escaped = Self.describe(error, phase: phase)
            lock.lock()
            let diagnostic = escaped + "; boundaries=" + observations.joined(separator: ",")
            lock.unlock()
            print(diagnostic)
            return diagnostic
        }
        private static func describe(_ error: Error, phase: String) -> String {
            if let failure = error as? LocalSaveBeforeReplacementFailure {
                return phase + "=LocalSaveBeforeReplacementFailure; " + describe(failure.underlying, phase: "underlying")
            }
            let value = error as NSError
            let cause = (error as? PendingLocalSaveStore.OwnershipError).map { String(describing: $0) }
                ?? "\(value.domain):\(value.code)"
            let nested = (value.userInfo[NSUnderlyingErrorKey] as? NSError).map { "; underlying=\($0.domain):\($0.code)" } ?? ""
            return phase + "=" + cause + nested
        }
    }

    static func reportLocalPublicationFailure(_ stage: String, _ error: Error, reference: DatabaseReference,
        file: StaticString = #filePath, line: UInt = #line) {
        if stage.hasPrefix("read-key") || stage.hasPrefix("rekey-") {
            let cause = (error as? PendingLocalSaveStore.OwnershipError).map { String(describing: $0) }
                ?? "\((error as NSError).domain):\((error as NSError).code)"
            XCTFail("Local publication rejected stage=\(stage) cause=\(cause); registry observation omitted while another accessor may own it", file: file, line: line)
            return
        }
        let current = DatabaseListStore.databases.first { $0.id == reference.id }
        let cause = (error as? PendingLocalSaveStore.OwnershipError).map { String(describing: $0) }
            ?? "\((error as NSError).domain):\((error as NSError).code)"
        XCTFail("Local publication rejected stage=\(stage) cause=\(cause) registered=\(current != nil) bookmarkMatches=\(current?.bookmarkData == reference.bookmarkData) epochDateMatches=\(current?.lastMasterKeyChangeAt == reference.lastMasterKeyChangeAt) preferenceMatches=\(current.map { PendingLocalSaveStore.KeyFilePreference($0) == PendingLocalSaveStore.KeyFilePreference(reference) } == true)", file: file, line: line)
    }

    static func cacheLocalSnapshotDiagnosingFailure(_ data: Data, for reference: DatabaseReference,
        file: StaticString = #filePath, line: UInt = #line) throws {
        try LocalDatabaseSaver.cacheLocalSnapshot(data, for: reference, onFailure: { stage, error in
            reportLocalPublicationFailure("save-cache-" + stage.rawValue, error, reference: reference, file: file, line: line)
        })
    }

    static func visibleRootGroupID(in rootGroup: KPGroup) -> UUID {
        if rootGroup.entries.isEmpty, rootGroup.groups.count == 1 {
            return rootGroup.groups[0].id
        }
        return rootGroup.id
    }

    static func fixtureURL(
        named name: String = "test",
        extension ext: String = "kdbx",
        subdirectory: String? = nil,
        bundle: Bundle
    ) throws -> URL {
        let url =
            bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) ??
            bundle.url(forResource: name, withExtension: ext)
        return try XCTUnwrap(url)
    }

    /// Bytes of a bundled resource that is not a database (key files); a
    /// database is opened through its `KDBXTestFixture` descriptor instead.
    static func fixtureData(
        named name: String,
        extension ext: String,
        subdirectory: String? = nil,
        bundle: Bundle
    ) throws -> Data {
        try Data(contentsOf: fixtureURL(named: name, extension: ext, subdirectory: subdirectory, bundle: bundle))
    }

    static func makeReference(
        for url: URL,
        id: UUID = UUID(),
        nickname: String? = nil,
        keyFileURL: URL? = nil,
        isQuickLaunch: Bool = false,
        lastOpenedAt: Date? = nil,
        addedAt: Date = .now,
        legacyKeychainFilename: String? = nil,
        autoFillEnabled: Bool = true
    ) throws -> DatabaseReference {
        let bookmarkData = try makeBookmarkData(for: url)

        let keyFileBookmarkData: Data?
        let keyFileFilename: String?
        if let keyFileURL {
            keyFileBookmarkData = try makeBookmarkData(for: keyFileURL)
            keyFileFilename = keyFileURL.lastPathComponent
        } else {
            keyFileBookmarkData = nil
            keyFileFilename = nil
        }

        return DatabaseReference(
            id: id,
            nickname: nickname,
            filename: url.lastPathComponent,
            bookmarkData: bookmarkData,
            keyFileBookmarkData: keyFileBookmarkData,
            keyFileFilename: keyFileFilename,
            isQuickLaunch: isQuickLaunch,
            lastOpenedAt: lastOpenedAt,
            addedAt: addedAt,
            colorTag: nil,
            legacyKeychainFilename: legacyKeychainFilename,
            autoFillEnabled: autoFillEnabled
        )
    }

    // #if os(macOS): the sandboxed macOS test host cannot create
    // `.withSecurityScope` bookmarks for fixtures living in DerivedData — a
    // sandboxed process can only bookmark files it has full access to, and no
    // powerbox (user-selection) grant is possible in a headless test run. When
    // direct creation is denied, the fixture is copied into the host's
    // temporary directory (inside the sandbox container, where scoped
    // bookmarks work — the filename is preserved) and the copy is bookmarked
    // instead. iOS behavior is unchanged: creation succeeds directly there.
    private static func makeBookmarkData(for url: URL) throws -> Data {
        #if os(macOS)
        do {
            return try SecurityScopedBookmarkManager.makeBookmarkData(for: url)
        } catch {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: copy)
            return try SecurityScopedBookmarkManager.makeBookmarkData(for: copy)
        }
        #else
        return try SecurityScopedBookmarkManager.makeBookmarkData(for: url)
        #endif
    }
}
