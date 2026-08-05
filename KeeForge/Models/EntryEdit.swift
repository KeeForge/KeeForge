import Foundation

struct EntryDraftPayload: Codable, Sendable, Equatable {
    struct TOTPConfiguration: Codable, Sendable, Equatable {
        var secret: String
        var decodedSecret: Data?
        var keeOTPSource: KeeOTPSource?
        var period: Int
        var digits: Int
        var algorithm: TOTPAlgorithm

        init(
            secret: String,
            decodedSecret: Data? = nil,
            keeOTPSource: KeeOTPSource? = nil,
            period: Int = 30,
            digits: Int = 6,
            algorithm: TOTPAlgorithm = .sha1
        ) {
            self.secret = secret
            self.decodedSecret = decodedSecret
            self.keeOTPSource = keeOTPSource
            self.period = period
            self.digits = digits
            self.algorithm = algorithm
        }
    }

    var title: String
    var username: String
    /// Plaintext password exists only while the caller is building an edit payload.
    var password: String
    var url: String
    var notes: String
    var customFields: [String: String]
    /// Custom-field keys to serialize with Protected=True. Keys absent from
    /// `customFields` are ignored; the passkey PEM key stays effective even
    /// though the value is diverted out of customFields before storage.
    var protectedCustomFieldKeys: Set<String>
    var tags: [String]
    var totpConfig: TOTPConfiguration?
    var lastModificationTime: Date?

    init(
        title: String = "",
        username: String = "",
        password: String = "",
        url: String = "",
        notes: String = "",
        customFields: [String: String] = [:],
        protectedCustomFieldKeys: Set<String> = [],
        tags: [String] = [],
        totpConfig: TOTPConfiguration? = nil,
        lastModificationTime: Date? = nil
    ) {
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.notes = notes
        self.customFields = customFields
        self.protectedCustomFieldKeys = protectedCustomFieldKeys
        self.tags = tags
        self.totpConfig = totpConfig
        self.lastModificationTime = lastModificationTime
    }
}

/// Codable mirror of `KPInheritableBool`, kept separate so the KDBX model type
/// doesn't have to carry a serialization format for the pending-edit log.
enum InheritableBoolPayload: String, Codable, Sendable, Equatable {
    case inherit
    case enabled
    case disabled

    var modelValue: KPInheritableBool {
        switch self {
        case .inherit: return .inherit
        case .enabled: return .enabled
        case .disabled: return .disabled
        }
    }
}

/// The group editor's whole payload. Separate from the single-field
/// `setGroupIcon` / `setGroupSearchingEnabled` edits, which the row context
/// menus still use as shortcuts.
struct GroupDraftPayload: Codable, Sendable, Equatable {
    var name: String
    var tags: [String]
    var notes: String
    var iconID: Int
    var searchingEnabled: InheritableBoolPayload?

    init(
        name: String = "",
        tags: [String] = [],
        notes: String = "",
        iconID: Int = 48,
        searchingEnabled: InheritableBoolPayload? = nil
    ) {
        self.name = name
        self.tags = tags
        self.notes = notes
        self.iconID = iconID
        self.searchingEnabled = searchingEnabled
    }
}

/// Which icon an entry displays.
///
/// The two cases are the two things KDBX can store, and they are exclusive:
/// `<CustomIconUUID>` outranks `<IconID>` in every client, so picking a standard
/// icon has to clear the custom one rather than sit alongside it.
enum EntryIconSelection: Codable, Sendable, Equatable {
    case standard(iconID: Int)
    /// Addresses an image the database already carries in `Meta/CustomIcons`.
    /// Adding one is not modeled — that section is round-tripped verbatim.
    case custom(uuid: UUID)
}

enum EntryEdit: Codable, Sendable, Equatable {
    case createEntry(parentGroupID: UUID, draft: EntryDraftPayload)
    case createGroup(parentGroupID: UUID, name: String)
    case updateEntry(entryID: UUID, draft: EntryDraftPayload)
    case deleteEntry(entryID: UUID, sendToRecycleBin: Bool)
    case deleteGroup(groupID: UUID, sendToRecycleBin: Bool)
    case setGroupSearchingEnabled(groupID: UUID, value: InheritableBoolPayload)
    case setGroupIcon(groupID: UUID, iconID: Int)
    case setEntryIcon(entryID: UUID, icon: EntryIconSelection)
    case updateGroup(groupID: UUID, draft: GroupDraftPayload)
    /// Bring a stored `<History>` version back as the entry's current state.
    /// `historyIndex` addresses `KPEntry.history` in storage order, which KDBX
    /// does not fix — KeePass appends oldest-first, this app prepends. Callers
    /// must not pass a position from a sorted display list.
    case restoreEntryVersion(entryID: UUID, historyIndex: Int)
}
