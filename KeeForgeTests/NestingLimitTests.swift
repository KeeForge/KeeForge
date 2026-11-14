import CryptoKit
import Foundation
import KDBXKit
import KDBXXML
import XCTest
@testable import KeeForge

/// The XML nesting limit through KeeForge's own open and save path, on the
/// 512 KiB stack of the background threads that run it.
final class NestingLimitTests: XCTestCase {
    private let compositeKey = KDBXCrypto.compositeKey(password: "nesting-limit-test")

    func testOpeningAHostilelyNestedDatabaseFailsInsteadOfCrashing() throws {
        let vault = try sealedVault(groupNesting: 5_000)
        let key = compositeKey

        let result = onSmallStack {
            Result { _ = try KDBXParser.parse(data: vault, compositeKey: key, sessionKey: SymmetricKey(size: .bits256), kdfPolicy: .mainApp) }
        }

        guard case .failure(let error) = result else { return XCTFail("a database nested 5,000 groups deep opened") }
        XCTAssertEqual(error as? KDBXDocument.ReadError, .nestingTooDeep)
        XCTAssertEqual(error.localizedDescription, "The database nests its groups or data too deeply to open.")
    }

    func testTheDeepestWritableDatabaseOpensAndSaves() throws {
        let vault = try sealedVault(groupNesting: KDBXDocument.maxElementDepth - 4)
        let key = compositeKey

        let result = onSmallStack {
            Result {
                let sessionKey = SymmetricKey(size: .bits256)
                let opened = try KDBXParser.parse(data: vault, compositeKey: key, sessionKey: sessionKey, kdfPolicy: .mainApp)
                let saved = try KDBXWriter.write(
                    rootGroup: opened.rootGroup,
                    meta: opened.meta,
                    compositeKey: key,
                    header: opened.header,
                    sessionKey: sessionKey,
                    kdfPolicy: .mainApp
                )
                _ = try KDBXParser.parse(data: saved, compositeKey: key, sessionKey: sessionKey, kdfPolicy: .mainApp)
            }
        }

        if case .failure(let error) = result { XCTFail("\(error)") }
    }

    func testSaveFailureNamesTheGroupOrEntryNestedTooDeeply() {
        let entry = KDBXDocument.Entry(strings: [.init(key: "Title", value: "Router", isProtected: false)])
        let group = KDBXDocument.Group(name: "Archive", entries: [entry])
        let document = KDBXDocument(root: .init(groups: [group]))
        let cases: [(KDBXDocument.WriteError.Location.Owner, String)] = [
            (.group(group.uuid), "The group “Archive” is nested too deeply, so the database can’t be saved. Move it closer to the top."),
            (.entry(entry.uuid), "The entry “Router” is in a group nested too deeply, so the database can’t be saved. Move it closer to the top."),
            (.meta, "The database nests its groups or data too deeply, so it can’t be saved."),
        ]
        for (owner, message) in cases {
            XCTAssertEqual(DocumentWriteFailure(.nestingTooDeep(at: owner), in: document).errorDescription, message)
        }
    }

    // MARK: - Helpers

    /// Past the read limit the XML is written by hand, since the writer
    /// refuses it.
    private func sealedVault(groupNesting: Int) throws -> Data {
        let header = try KDBXContainerWriter.prepareHeader(
            .fresh(.init(cipher: .chaCha20, kdfParameters: KDBXKeyDerivation.aesKDF(rounds: 1, seed: nil).parameters)),
            requiredMinorVersion: 1
        )
        let xml: Data
        if groupNesting > KDBXDocument.maxElementDepth {
            xml = Data(("<KeePassFile><Root>" + String(repeating: "<Group>", count: groupNesting)
                + String(repeating: "</Group>", count: groupNesting) + "</Root></KeePassFile>").utf8)
        } else {
            let times = KDBXDocument.Times(creationTime: Date(timeIntervalSince1970: 0))
            var group = KDBXDocument.Group(name: "1", times: times)
            for level in 2...groupNesting {
                group = KDBXDocument.Group(name: String(level), times: times, groups: [group])
            }
            xml = try KDBXDocument(root: .init(groups: [group]))
                .serialized(innerStream: .chaCha20, innerStreamKey: header.innerStreamKey)
        }
        let key = compositeKey
        return try KDBXContainerWriter.seal(xml: xml, header: header) {
            try KDBXKeyDerivation.deriveKey(compositeKey: key, parameters: $0, policy: .mainApp)
        }
    }

    private func onSmallStack(_ work: @escaping @Sendable () -> Result<Void, Error>) -> Result<Void, Error> {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.result = work()
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        return box.result
    }
}

private final class ResultBox: @unchecked Sendable {
    var result: Result<Void, Error> = .success(())
}
