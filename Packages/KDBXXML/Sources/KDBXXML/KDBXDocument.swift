import Foundation
import KDBXKit

/// The KeePass database XML (`<KeePassFile>`) as typed values.
///
/// Elements the document models are typed properties. Everything else is kept
/// verbatim in an `OpaqueXMLNodes` on the owning element, at the position it
/// had among the typed siblings, so a foreign file survives a read-write cycle.
/// Optional properties are three-state where the format is: `nil` means the
/// source had no element, and the writer then emits none.
///
/// Protected values (`Protected="True"`) are plaintext here. The reader removes
/// the inner-stream mask in document order and the writer applies it again.
public struct KDBXDocument: Sendable, Hashable {
    public var meta: Meta
    public var root: Root

    public init(meta: Meta = Meta(), root: Root = Root()) {
        self.meta = meta
        self.root = root
    }

    /// Reads decrypted, decompressed payload XML whose protected values are
    /// masked with the header's inner stream. Throws `ReadError`, or KDBXKit's
    /// `ParseError.unsupportedProtectedFieldStream` for an unknown stream ID.
    public static func read(xml: Data, innerStreamID: UInt32, innerStreamKey: Data) throws -> KDBXDocument {
        try DocumentReader(innerStream: KDBXInnerStream(streamID: innerStreamID, key: innerStreamKey)).read(xml)
    }

    /// The document as UTF-8 XML with a byte order mark, protected values
    /// masked with a new stream of `innerStream` under `innerStreamKey`.
    /// KDBX 4 saves use `.chaCha20`. Throws `WriteError` before building any
    /// output.
    public func serialized(innerStream: KDBXInnerStream.Algorithm, innerStreamKey: Data) throws -> Data {
        try DocumentWriter(innerStream: KDBXInnerStream(algorithm: innerStream, key: innerStreamKey)).write(self)
    }

    /// Throws `TextError.invalidXMLCharacter` for the first scalar XML 1.0
    /// cannot carry, even as a character reference. Editors run it before
    /// accepting text; `serialized` checks the whole document the same way.
    public static func validate(text: String) throws {
        if let scalar = XMLText.firstInvalidScalar(in: text) {
            throw TextError.invalidXMLCharacter(scalar)
        }
    }

    public enum ReadError: Error, Equatable, Sendable {
        /// The payload is not well-formed XML. Position is 1-based.
        case malformedXML(line: Int, column: Int)
        /// The document element is not `<KeePassFile>`.
        case unexpectedRootElement(String)
        /// A protected value is not base64, so the inner stream position of
        /// every later value is unknown.
        case invalidProtectedValue
    }

    public enum TextError: Error, Equatable, Sendable {
        case invalidXMLCharacter(Unicode.Scalar)
    }

    public enum WriteError: Error, Equatable, Sendable {
        /// Text XML 1.0 cannot carry, found before any output was built.
        case invalidXMLCharacter(Unicode.Scalar, at: Location)

        /// The element that holds the character, and the group or entry it
        /// belongs to.
        public struct Location: Sendable, Hashable {
            public enum Owner: Sendable, Hashable {
                case meta
                case root
                case group(UUID)
                case entry(UUID)
                /// A version in an entry's `<History>`, by its own UUID, which
                /// is normally the entry's.
                case historyEntry(UUID)
            }

            public enum Part: Sendable, Hashable {
                /// A child element by name, typed (`Name`, `Notes`, `Tags`) or
                /// preserved in `unknownXML` at any depth. `nil` for a
                /// preserved node that is not an element.
                case element(String?)
                /// An entry `<String>`, its key or unprotected value.
                case field(key: String)
                /// An entry `<Binary>` name.
                case attachment(key: String)
            }

            public var owner: Owner
            public var part: Part

            public init(owner: Owner, part: Part) {
                self.owner = owner
                self.part = part
            }
        }
    }
}

extension KDBXDocument {
    /// `<Meta>`. Only the settings below are typed; everything else, including
    /// `<CustomIcons>`, stays in `unknownXML`.
    public struct Meta: Sendable, Hashable {
        /// `<RecycleBinUUID>`. `nil` when the source has no element.
        public var recycleBin: RecycleBin?
        public var maintenanceHistoryDays: Int?
        public var historyMaxItems: Int?
        public var historyMaxSize: Int64?
        public var unknownXML: OpaqueXMLNodes

        public init(
            recycleBin: RecycleBin? = nil,
            maintenanceHistoryDays: Int? = nil,
            historyMaxItems: Int? = nil,
            historyMaxSize: Int64? = nil,
            unknownXML: OpaqueXMLNodes = .empty
        ) {
            self.recycleBin = recycleBin
            self.maintenanceHistoryDays = maintenanceHistoryDays
            self.historyMaxItems = historyMaxItems
            self.historyMaxSize = historyMaxSize
            self.unknownXML = unknownXML
        }
    }

    /// The value of `<RecycleBinUUID>`.
    public enum RecycleBin: Sendable, Hashable {
        /// The all-zero UUID: the database has no recycle bin group.
        case unset
        /// A group UUID, which need not name a group in the document.
        /// `.group` of the all-zero UUID writes the same bytes as `.unset`.
        case group(UUID)
    }

    /// `<Root>`. KeePass keeps one group here; entries are tolerated.
    public struct Root: Sendable, Hashable {
        public var entries: [Entry]
        public var groups: [Group]
        public var deletedObjects: [DeletedObject]
        public var unknownXML: OpaqueXMLNodes

        public init(
            entries: [Entry] = [],
            groups: [Group] = [],
            deletedObjects: [DeletedObject] = [],
            unknownXML: OpaqueXMLNodes = .empty
        ) {
            self.entries = entries
            self.groups = groups
            self.deletedObjects = deletedObjects
            self.unknownXML = unknownXML
        }
    }

    public struct Group: Sendable, Hashable {
        /// A group whose source UUID is missing, unreadable, or all-zero gets a
        /// random one.
        public var uuid: UUID
        public var name: String
        public var notes: String?
        /// 48 (folder) when the element is absent, 0 when unreadable.
        public var iconID: Int
        public var isExpanded: Bool
        public var times: Times
        public var enableSearching: InheritableBool?
        /// KDBX 4.1. Written comma-joined; read split on `,` and `;`.
        public var tags: [String]?
        public var entries: [Entry]
        public var groups: [Group]
        public var unknownXML: OpaqueXMLNodes

        public init(
            uuid: UUID = UUID(),
            name: String = "",
            notes: String? = nil,
            iconID: Int = 48,
            isExpanded: Bool = true,
            times: Times = Times(),
            enableSearching: InheritableBool? = nil,
            tags: [String]? = nil,
            entries: [Entry] = [],
            groups: [Group] = [],
            unknownXML: OpaqueXMLNodes = .empty
        ) {
            self.uuid = uuid
            self.name = name
            self.notes = notes
            self.iconID = iconID
            self.isExpanded = isExpanded
            self.times = times
            self.enableSearching = enableSearching
            self.tags = tags
            self.entries = entries
            self.groups = groups
            self.unknownXML = unknownXML
        }
    }

    public struct Entry: Sendable, Hashable {
        /// An entry whose source UUID is missing, unreadable, or all-zero gets a
        /// random one.
        public var uuid: UUID
        /// 0 when absent or unreadable.
        public var iconID: Int
        public var tags: [String]?
        public var times: Times
        /// `<String>` elements in document order. Duplicate and empty keys are
        /// kept as read.
        public var strings: [Field]
        public var binaries: [BinaryReference]
        public var history: [Entry]
        public var unknownXML: OpaqueXMLNodes

        public init(
            uuid: UUID = UUID(),
            iconID: Int = 0,
            tags: [String]? = nil,
            times: Times = Times(),
            strings: [Field] = [],
            binaries: [BinaryReference] = [],
            history: [Entry] = [],
            unknownXML: OpaqueXMLNodes = .empty
        ) {
            self.uuid = uuid
            self.iconID = iconID
            self.tags = tags
            self.times = times
            self.strings = strings
            self.binaries = binaries
            self.history = history
            self.unknownXML = unknownXML
        }
    }

    /// The typed children of `<Times>`. The rest (`ExpiryTime`, `Expires`,
    /// `LastAccessTime`, `UsageCount`) stay in the owner's `unknownXML` under
    /// the path `["Times"]`.
    public struct Times: Sendable, Hashable {
        public var creationTime: Date?
        public var lastModificationTime: Date?
        public var locationChanged: Date?

        public init(creationTime: Date? = nil, lastModificationTime: Date? = nil, locationChanged: Date? = nil) {
            self.creationTime = creationTime
            self.lastModificationTime = lastModificationTime
            self.locationChanged = locationChanged
        }
    }

    /// An entry `<String>`.
    public struct Field: Sendable, Hashable {
        public var key: String
        public var value: String
        public var isProtected: Bool

        public init(key: String, value: String, isProtected: Bool = false) {
            self.key = key
            self.value = value
            self.isProtected = isProtected
        }
    }

    /// An entry `<Binary>`: a name and an index into the inner-header binary
    /// pool. A `<Binary>` without a numeric `Ref` stays opaque.
    public struct BinaryReference: Sendable, Hashable {
        public var key: String
        public var ref: Int
        /// The number of other typed entry children (attachments excluded)
        /// before this one, which is where the writer puts it back. 0 for a new
        /// attachment, which then goes before `<History>`.
        public var insertionIndex: Int

        public init(key: String, ref: Int, insertionIndex: Int = 0) {
            self.key = key
            self.ref = ref
            self.insertionIndex = insertionIndex
        }
    }

    /// A `<DeletedObject>` tombstone. One missing either field is dropped.
    public struct DeletedObject: Sendable, Hashable {
        public var uuid: UUID
        public var deletionTime: Date

        public init(uuid: UUID, deletionTime: Date) {
            self.uuid = uuid
            self.deletionTime = deletionTime
        }
    }

    /// A tri-state group flag such as `<EnableSearching>`: explicit, or `null`
    /// to take the parent's value.
    public enum InheritableBool: Sendable, Hashable, CaseIterable {
        case inherit
        case enabled
        case disabled
    }

    /// One `Meta/CustomIcons/Icon`, decoded for display.
    public struct CustomIcon: Sendable, Hashable {
        public var data: Data
        /// KDBX 4.1 `<Name>`.
        public var name: String?

        public init(data: Data, name: String? = nil) {
            self.data = data
            self.name = name
        }
    }
}
