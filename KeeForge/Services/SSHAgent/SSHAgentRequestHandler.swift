#if os(macOS)
import Foundation
import os

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
    /// KeeAgent and KeePassXC write about a kilobyte. A larger attachment of
    /// that name is not parsed, on any request.
    static let maximumLength = 64 * 1024

    static func keyAttachmentName(in settings: Data) -> String? {
        guard settings.count <= maximumLength else { return nil }
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

/// Parsed keys of the entries the agent serves, kept so a request does not
/// parse an unchanged key file again; for RSA that parse derives the CRT
/// exponents. A key is reused only for the same entry under the same lease
/// with byte-identical key file content. Nothing outlives the lease: the
/// controller empties the cache when the session locks, the selection
/// changes, or the agent stops, and each request drops what its own read of
/// the session no longer offers.
final class SSHAgentKeyCache: Sendable {
    private struct Entry {
        let lease: SSHAgentLease
        let privateKeyFile: Data
        let key: SSHAgentKey
    }

    private struct State {
        var entries: [UUID: Entry] = [:]
        var generation = 0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// Read before the session is; `store` refuses a key parsed from a read
    /// that `removeAll` has overtaken since.
    var generation: Int {
        state.withLockUnchecked { $0.generation }
    }

    var isEmpty: Bool {
        state.withLockUnchecked { $0.entries.isEmpty }
    }

    func key(for source: SSHAgentKeySource, privateKeyFile: Data) -> SSHAgentKey? {
        state.withLockUnchecked { state in
            guard let entry = state.entries[source.entryID],
                  entry.lease == source.lease,
                  entry.privateKeyFile == privateKeyFile
            else { return nil }
            return entry.key
        }
    }

    func store(_ key: SSHAgentKey, for source: SSHAgentKeySource, privateKeyFile: Data, generation: Int) {
        state.withLockUnchecked { state in
            guard state.generation == generation else { return }
            state.entries[source.entryID] = Entry(lease: source.lease, privateKeyFile: privateKeyFile, key: key)
        }
    }

    func keep(only sources: [SSHAgentKeySource]) {
        let current = Dictionary(sources.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
        state.withLockUnchecked { state in
            state.entries = state.entries.filter { id, entry in
                guard let source = current[id] else { return false }
                return source.lease == entry.lease && source.privateKeyFile == entry.privateKeyFile
            }
        }
    }

    func removeAll() {
        state.withLockUnchecked { state in
            state.entries = [:]
            state.generation += 1
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
    var keyCache = SSHAgentKeyCache()

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

    /// An SSH client drops an answer longer than the message limit, so a key
    /// that no longer fits is left out. It can still sign when asked for.
    private func identitiesAnswer() -> Data {
        var identities: [(publicKeyBlob: Data, comment: Data)] = []
        var length = 1 + 4
        // A key stored on two entries is offered by the first.
        var seen = Set<Data>()
        for available in availableKeys() where seen.insert(available.key.publicKeyBlob).inserted {
            let comment = available.key.comment.isEmpty ? available.source.entryTitle : available.key.comment
            let identity = (publicKeyBlob: available.key.publicKeyBlob, comment: Data(comment.utf8))
            let identityLength = 4 + identity.publicKeyBlob.count + 4 + identity.comment.count
            guard length + identityLength <= Self.maximumMessageLength else { continue }
            length += identityLength
            identities.append(identity)
        }
        var writer = SSHWireWriter()
        writer.writeByte(MessageType.identitiesAnswer.rawValue)
        writer.writeUInt32(UInt32(identities.count))
        for identity in identities {
            writer.writeString(identity.publicKeyBlob)
            writer.writeString(identity.comment)
        }
        return writer.data
    }

    private func signResponse(reading reader: inout SSHWireReader) throws -> Data {
        let publicKeyBlob = try reader.readString()
        let data = try reader.readString()
        let flags = try reader.readUInt32()
        // Lazy: parsing stops at the entry that holds the requested key.
        guard let available = availableKeys().first(where: { $0.key.publicKeyBlob == publicKeyBlob }) else {
            return Self.failure
        }
        let signature = try available.key.signature(for: data, flags: flags)
        // A lock, deselection, or replaced key attachment that lands while
        // signing withdraws the key before the signature leaves the process.
        let source = available.source
        guard currentSources().sources.contains(where: {
            $0.entryID == source.entryID && $0.lease == source.lease && $0.privateKeyFile == available.privateKeyFile
        }) else {
            return Self.failure
        }
        var writer = SSHWireWriter()
        writer.writeByte(MessageType.signResponse.rawValue)
        writer.writeString(signature)
        return writer.data
    }

    /// One read of the session, with the cache brought in line with it.
    private func currentSources() -> (sources: [SSHAgentKeySource], generation: Int) {
        let generation = keyCache.generation
        let sources = keySources()
        keyCache.keep(only: sources)
        return (sources, generation)
    }

    /// Every usable key, lazily and in entry order.
    private func availableKeys() -> some Sequence<AvailableKey> {
        let (sources, generation) = currentSources()
        return sources.lazy.compactMap { [keyCache] source in
            AvailableKey(source: source, cache: keyCache, generation: generation)
        }
    }

    private struct AvailableKey {
        let source: SSHAgentKeySource
        let privateKeyFile: Data
        let key: SSHAgentKey

        init?(source: SSHAgentKeySource, cache: SSHAgentKeyCache, generation: Int) {
            guard let file = source.privateKeyFile else { return nil }
            if let cached = cache.key(for: source, privateKeyFile: file) {
                key = cached
            } else {
                guard let parsed = try? SSHAgentKey(privateKeyFile: file) else { return nil }
                cache.store(parsed, for: source, privateKeyFile: file, generation: generation)
                key = parsed
            }
            self.source = source
            privateKeyFile = file
        }
    }
}
#endif
