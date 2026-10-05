#if os(macOS)
import Foundation

/// One attachment of an entry the agent may read a key from.
struct SSHAgentAttachment: Sendable {
    let name: String
    let data: Data
}

/// Ties a key to the unlocked session it came from. A lock starts a new lock
/// cycle, so a lease taken before the lock never matches one taken after it.
struct SSHAgentLease: Sendable, Equatable {
    let session: ObjectIdentifier
    let lockCycleID: Int
}

/// An entry the user chose to serve, captured from the unlocked session on the
/// main actor. The key itself is located and parsed off the main actor.
struct SSHAgentKeySource: Sendable {
    let entryID: UUID
    let entryTitle: String
    let attachments: [SSHAgentAttachment]
    let lease: SSHAgentLease

    /// The attachment holding the private key: the one `KeeAgent.settings`
    /// names (KeeAgent, KeePassXC, and Strongbox write it), otherwise the
    /// first attachment that looks like a private key file.
    var privateKeyFile: Data? {
        let settingsName = KeeAgentSettings.attachmentName
        if let settings = attachments.first(where: { $0.name == settingsName }),
           let keyName = KeeAgentSettings.keyAttachmentName(in: settings.data),
           let named = attachments.first(where: { $0.name == keyName }) {
            return named.data
        }
        return attachments.first {
            $0.name != settingsName && SSHAgentKey.looksLikePrivateKey($0.data)
        }?.data
    }
}

/// Reads the key location from a KeeAgent entry settings attachment. Only an
/// attachment location is honored; a file path on disk is outside the sandbox.
enum KeeAgentSettings {
    static let attachmentName = "KeeAgent.settings"

    static func keyAttachmentName(in settings: Data) -> String? {
        let reader = Reader()
        let parser = XMLParser(data: settings)
        parser.delegate = reader
        guard parser.parse(), reader.selectedType.map({ $0 == "attachment" }) ?? true else { return nil }
        return reader.attachmentName.flatMap { $0.isEmpty ? nil : $0 }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        private(set) var selectedType: String?
        private(set) var attachmentName: String?
        private var path: [String] = []
        private var text = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            path.append(elementName)
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            switch path {
            case ["EntrySettings", "Location", "SelectedType"]:
                selectedType = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case ["EntrySettings", "Location", "AttachmentName"]:
                attachmentName = text
            default:
                break
            }
            path.removeLast()
            text = ""
        }
    }
}

/// Answers SSH agent protocol messages (draft-miller-ssh-agent) from the keys
/// `keySources` offers at the moment each request arrives. Only listing and
/// signing are supported; adding, removing, and locking keys belong to the
/// database, so those requests fail.
struct SSHAgentRequestHandler: Sendable {
    enum MessageType: UInt8 {
        case failure = 5
        case requestIdentities = 11
        case identitiesAnswer = 12
        case signRequest = 13
        case signResponse = 14
    }

    /// Matches OpenSSH's own agent message limit.
    static let maximumMessageLength = 256 * 1024

    let keySources: @Sendable () -> [SSHAgentKeySource]

    /// `request` and the result are message bodies without the length prefix.
    func response(to request: Data) -> Data {
        var reader = SSHWireReader(request)
        switch (try? reader.readByte()).flatMap(MessageType.init(rawValue:)) {
        case .requestIdentities:
            return identitiesAnswer()
        case .signRequest:
            return (try? signResponse(reading: &reader)) ?? Self.failure
        default:
            return Self.failure
        }
    }

    private static var failure: Data { Data([MessageType.failure.rawValue]) }

    private func identitiesAnswer() -> Data {
        let keys = availableKeys()
        var writer = SSHWireWriter()
        writer.writeByte(MessageType.identitiesAnswer.rawValue)
        writer.writeUInt32(UInt32(keys.count))
        for available in keys {
            writer.writeString(available.key.publicKeyBlob)
            writer.writeString(available.key.comment.isEmpty ? available.source.entryTitle : available.key.comment)
        }
        return writer.data
    }

    private func signResponse(reading reader: inout SSHWireReader) throws -> Data {
        let publicKeyBlob = try reader.readString()
        let data = try reader.readString()
        let flags = try reader.readUInt32()
        guard let available = availableKeys().first(where: { $0.key.publicKeyBlob == publicKeyBlob }) else {
            return Self.failure
        }
        let signature = try available.key.signature(for: data, flags: flags)
        // A lock or deselection that lands while signing withdraws the key
        // before the signature leaves the process.
        let source = available.source
        guard keySources().contains(where: { $0.entryID == source.entryID && $0.lease == source.lease }) else {
            return Self.failure
        }
        var writer = SSHWireWriter()
        writer.writeByte(MessageType.signResponse.rawValue)
        writer.writeString(signature)
        return writer.data
    }

    /// Every usable key once, in entry order; a key stored on two entries is
    /// offered by the first.
    private func availableKeys() -> [AvailableKey] {
        var seen = Set<Data>()
        return keySources().compactMap { source in
            guard let file = source.privateKeyFile,
                  let key = try? SSHAgentKey(privateKeyFile: file),
                  seen.insert(key.publicKeyBlob).inserted
            else { return nil }
            return AvailableKey(source: source, key: key)
        }
    }

    private struct AvailableKey {
        let source: SSHAgentKeySource
        let key: SSHAgentKey
    }
}
#endif
