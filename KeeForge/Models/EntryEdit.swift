import Foundation

struct EntryDraftPayload: Codable, Sendable, Equatable {
    struct TOTPConfiguration: Codable, Sendable, Equatable {
        var secret: String
        var decodedSecret: Data?
        var period: Int
        var digits: Int
        var algorithm: TOTPAlgorithm

        init(
            secret: String,
            decodedSecret: Data? = nil,
            period: Int = 30,
            digits: Int = 6,
            algorithm: TOTPAlgorithm = .sha1
        ) {
            self.secret = secret
            self.decodedSecret = decodedSecret
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
        self.tags = tags
        self.totpConfig = totpConfig
        self.lastModificationTime = lastModificationTime
    }
}

enum EntryEdit: Codable, Sendable, Equatable {
    case createEntry(parentGroupID: UUID, draft: EntryDraftPayload)
    case createGroup(parentGroupID: UUID, name: String)
    case updateEntry(entryID: UUID, draft: EntryDraftPayload)
    case deleteEntry(entryID: UUID, sendToRecycleBin: Bool)
    case deleteGroup(groupID: UUID, sendToRecycleBin: Bool)
}
