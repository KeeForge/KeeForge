#if os(macOS)
import CryptoKit
import os
import XCTest
@testable import KeeForge

/// The SSH agent protocol answers over in-memory key sources: listing,
/// signing, a key withdrawn mid-signature, and requests the agent refuses.
final class SSHAgentRequestHandlerTests: XCTestCase {
    private typealias Keys = SSHAgentTestKeys

    private let sessionObject = NSObject()
    private var lease: SSHAgentLease {
        SSHAgentLease(session: ObjectIdentifier(sessionObject), lockCycleID: 1)
    }

    // MARK: - Listing

    func testListsEachChosenKeyWithItsCommentOrTheEntryTitle() throws {
        let handler = makeHandler([
            source("Laptop", ["id_ed25519": Keys.ed25519.fileData]),
            source("Deploy Key", ["id_rsa": Keys.rsaWrittenByCryptography.fileData]),
        ])

        let identities = try Self.identities(in: handler.response(to: Self.requestIdentities))

        XCTAssertEqual(identities.map(\.blob), [Keys.ed25519.publicKeyData, Keys.rsa.publicKeyData])
        XCTAssertEqual(identities.map(\.comment), [Keys.ed25519.comment, "Deploy Key"])
    }

    func testOffersAKeyStoredOnTwoEntriesOnce() throws {
        let handler = makeHandler([
            source("First", ["id_ed25519": Keys.ed25519.fileData]),
            source("Second", ["id_ed25519": Keys.ed25519WrittenByCryptography.fileData]),
        ])

        let identities = try Self.identities(in: handler.response(to: Self.requestIdentities))

        XCTAssertEqual(identities.map(\.comment), [Keys.ed25519.comment])
    }

    func testOffersNothingFromEntriesWithoutAUsableKey() throws {
        let handler = makeHandler([
            source("Protected", ["id_ed25519": Keys.ed25519PassphraseProtected.fileData]),
            source("Legacy", ["id_rsa": Data(Keys.rsaTraditionalPEM.utf8)]),
            source("Notes", ["notes.txt": Data("not a key".utf8)]),
        ])

        XCTAssertEqual(try Self.identities(in: handler.response(to: Self.requestIdentities)).count, 0)
    }

    func testOffersNothingWithoutKeySources() throws {
        let handler = makeHandler([])

        XCTAssertEqual(try Self.identities(in: handler.response(to: Self.requestIdentities)).count, 0)
    }

    // MARK: - KeeAgent settings

    func testKeeAgentSettingsChooseTheKeyAttachment() throws {
        let handler = makeHandler([
            source("Server", [
                "backup.pem": Keys.rsa.fileData,
                "id_ed25519": Keys.ed25519.fileData,
                KeeAgentSettings.attachmentName: Self.keeAgentSettings(selectedType: "attachment", attachmentName: "id_ed25519"),
            ]),
        ])

        let identities = try Self.identities(in: handler.response(to: Self.requestIdentities))

        XCTAssertEqual(identities.map(\.blob), [Keys.ed25519.publicKeyData])
    }

    func testKeeAgentSettingsPointingAtAFileFallBackToTheFirstKeyAttachment() throws {
        let handler = makeHandler([
            source("Server", [
                "backup.pem": Keys.rsa.fileData,
                "id_ed25519": Keys.ed25519.fileData,
                KeeAgentSettings.attachmentName: Self.keeAgentSettings(selectedType: "file", attachmentName: "id_ed25519"),
            ]),
        ])

        let identities = try Self.identities(in: handler.response(to: Self.requestIdentities))

        XCTAssertEqual(identities.map(\.blob), [Keys.rsa.publicKeyData])
    }

    // MARK: - Signing

    func testSignsWithTheRequestedKey() throws {
        let handler = makeHandler([
            source("P-256", ["id_ecdsa": Keys.ecdsaP256.fileData]),
            source("Ed25519", ["id_ed25519": Keys.ed25519.fileData]),
        ])

        let response = handler.response(to: Self.signRequest(for: Keys.ed25519.publicKeyData, flags: 0))

        var reader = SSHWireReader(response)
        let messageType = try reader.readByte()
        var signature = SSHWireReader(try reader.readString())
        XCTAssertEqual(messageType, SSHAgentRequestHandler.MessageType.signResponse.rawValue)
        XCTAssertTrue(reader.isAtEnd)
        let signatureType = try signature.readString()
        let bytes = try signature.readString()
        XCTAssertEqual(signatureType, Data("ssh-ed25519".utf8))
        var publicKey = SSHWireReader(Keys.ed25519.publicKeyData)
        _ = try publicKey.readString()
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: try publicKey.readString())
        XCTAssertTrue(verifier.isValidSignature(bytes, for: Keys.message))
    }

    func testRSASignRequestUsesTheRequestedHash() throws {
        let handler = makeHandler([source("RSA", ["id_rsa": Keys.rsa.fileData])])

        let response = handler.response(to: Self.signRequest(for: Keys.rsa.publicKeyData, flags: SSHAgentKey.rsaSHA512Flag))

        var reader = SSHWireReader(response)
        let messageType = try reader.readByte()
        let signature = try reader.readString()
        XCTAssertEqual(messageType, SSHAgentRequestHandler.MessageType.signResponse.rawValue)
        XCTAssertEqual(signature.base64EncodedString(), Keys.rsaSHA512SignatureBlob)
    }

    func testRSASignRequestWithoutASHA2FlagFails() {
        let handler = makeHandler([source("RSA", ["id_rsa": Keys.rsa.fileData])])

        XCTAssertEqual(handler.response(to: Self.signRequest(for: Keys.rsa.publicKeyData, flags: 0)), Self.failure)
    }

    func testSignRequestForAKeyNotOfferedFails() {
        let handler = makeHandler([source("Ed25519", ["id_ed25519": Keys.ed25519.fileData])])

        XCTAssertEqual(handler.response(to: Self.signRequest(for: Keys.ecdsaP384.publicKeyData, flags: 0)), Self.failure)
    }

    /// The handler reads the sources once to find the key and again after
    /// signing; a lock in between must withhold the signature.
    func testKeyWithdrawnWhileSigningGetsNoSignature() {
        let offered = source("Ed25519", ["id_ed25519": Keys.ed25519.fileData])
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let handler = SSHAgentRequestHandler {
            reads.withLock { count in
                count += 1
                return count == 1 ? [offered] : []
            }
        }

        XCTAssertEqual(handler.response(to: Self.signRequest(for: Keys.ed25519.publicKeyData, flags: 0)), Self.failure)
        XCTAssertEqual(reads.withLock { $0 }, 2)
    }

    func testKeyFromAnEarlierLockCycleGetsNoSignature() {
        let entryID = UUID()
        let before = source("Ed25519", ["id_ed25519": Keys.ed25519.fileData], id: entryID)
        let after = SSHAgentKeySource(
            entryID: entryID,
            entryTitle: before.entryTitle,
            attachments: before.attachments,
            lease: SSHAgentLease(session: before.lease.session, lockCycleID: before.lease.lockCycleID + 1)
        )
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let handler = SSHAgentRequestHandler {
            reads.withLock { count in
                count += 1
                return count == 1 ? [before] : [after]
            }
        }

        XCTAssertEqual(handler.response(to: Self.signRequest(for: Keys.ed25519.publicKeyData, flags: 0)), Self.failure)
    }

    // MARK: - Refused requests

    func testRequestsBeyondListingAndSigningFail() {
        let handler = makeHandler([source("Ed25519", ["id_ed25519": Keys.ed25519.fileData])])
        var addIdentity = SSHWireWriter()
        addIdentity.writeByte(17)
        addIdentity.writeString("ssh-ed25519")
        var lockAgent = SSHWireWriter()
        lockAgent.writeByte(22)
        lockAgent.writeString("passphrase")
        var sessionBind = SSHWireWriter()
        sessionBind.writeByte(27)
        sessionBind.writeString("session-bind@openssh.com")

        let requests: [Data] = [
            addIdentity.data,
            Data([18]),
            Data([19]),
            lockAgent.data,
            sessionBind.data,
            Data(),
            Self.signRequest(for: Keys.ed25519.publicKeyData, flags: 0).dropLast(2),
        ]
        for request in requests {
            XCTAssertEqual(handler.response(to: Data(request)), Self.failure, "\(Array(request.prefix(1)))")
        }
    }

    // MARK: - Helpers

    private static let requestIdentities = Data([SSHAgentRequestHandler.MessageType.requestIdentities.rawValue])
    private static let failure = Data([SSHAgentRequestHandler.MessageType.failure.rawValue])

    private func makeHandler(_ sources: [SSHAgentKeySource]) -> SSHAgentRequestHandler {
        SSHAgentRequestHandler { sources }
    }

    private func source(_ title: String, _ attachments: KeyValuePairs<String, Data>, id: UUID = UUID()) -> SSHAgentKeySource {
        SSHAgentKeySource(
            entryID: id,
            entryTitle: title,
            attachments: attachments.map { SSHAgentAttachment(name: $0.key, data: $0.value) },
            lease: lease
        )
    }

    private static func signRequest(for publicKeyBlob: Data, flags: UInt32) -> Data {
        var writer = SSHWireWriter()
        writer.writeByte(SSHAgentRequestHandler.MessageType.signRequest.rawValue)
        writer.writeString(publicKeyBlob)
        writer.writeString(Keys.message)
        writer.writeUInt32(flags)
        return writer.data
    }

    private static func identities(in response: Data) throws -> [(blob: Data, comment: String)] {
        var reader = SSHWireReader(response)
        guard try reader.readByte() == SSHAgentRequestHandler.MessageType.identitiesAnswer.rawValue else {
            throw SSHAgentKeyError.malformed
        }
        let count = try reader.readUInt32()
        var identities: [(blob: Data, comment: String)] = []
        for _ in 0 ..< count {
            let blob = try reader.readString()
            let comment = String(decoding: try reader.readString(), as: UTF8.self)
            identities.append((blob, comment))
        }
        XCTAssertTrue(reader.isAtEnd)
        return identities
    }

    /// The UTF-16 settings document KeeAgent and KeePassXC write.
    private static func keeAgentSettings(selectedType: String, attachmentName: String) -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-16"?>
        <EntrySettings xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <AllowUseOfSshKey>true</AllowUseOfSshKey>
          <AddAtDatabaseOpen>true</AddAtDatabaseOpen>
          <RemoveAtDatabaseClose>true</RemoveAtDatabaseClose>
          <UseConfirmConstraintWhenAdding>false</UseConfirmConstraintWhenAdding>
          <UseLifetimeConstraintWhenAdding>false</UseLifetimeConstraintWhenAdding>
          <LifetimeConstraintDuration>600</LifetimeConstraintDuration>
          <Location>
            <SelectedType>\(selectedType)</SelectedType>
            <AttachmentName>\(attachmentName)</AttachmentName>
            <SaveAttachmentToTempFile>false</SaveAttachmentToTempFile>
            <FileName />
          </Location>
        </EntrySettings>
        """
        return document.data(using: .utf16) ?? Data()
    }
}
#endif
