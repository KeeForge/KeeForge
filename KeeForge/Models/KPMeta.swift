import Foundation
import KDBXXML

/// A tombstone record for a permanently deleted entry or group, used by
/// KeePass sync/merge to prevent resurrecting deleted objects.
struct KPDeletedObject: Sendable, Hashable {
    let uuid: UUID
    let deletionTime: Date
}

struct KPMeta: Sendable, Hashable {
    var recycleBinUUID: UUID?
    var hasRecycleBinUUIDElement: Bool
    var maintenanceHistoryDays: Int?
    var historyMaxItems: Int?
    var historyMaxSize: Int64?
    var unknownXML: OpaqueXMLNodes
    var deletedObjects: [KPDeletedObject]
    /// Decoded image data of `Meta/CustomIcons`, keyed by icon UUID. Read-only
    /// display copy: the source elements stay in `unknownXML` so the writer
    /// round-trips them verbatim.
    var customIcons: [UUID: Data]

    var customIconNames: [UUID: String]

    static let defaultMaintenanceHistoryDays = 365
    static let defaultHistoryMaxItems = 10
    static let defaultHistoryMaxSize: Int64 = 6 * 1024 * 1024

    init(
        recycleBinUUID: UUID? = nil,
        hasRecycleBinUUIDElement: Bool = false,
        maintenanceHistoryDays: Int? = nil,
        historyMaxItems: Int? = nil,
        historyMaxSize: Int64? = nil,
        unknownXML: OpaqueXMLNodes = .empty,
        deletedObjects: [KPDeletedObject] = [],
        customIcons: [UUID: Data] = [:],
        customIconNames: [UUID: String] = [:]
    ) {
        self.recycleBinUUID = recycleBinUUID
        self.hasRecycleBinUUIDElement = hasRecycleBinUUIDElement
        self.maintenanceHistoryDays = maintenanceHistoryDays
        self.historyMaxItems = historyMaxItems
        self.historyMaxSize = historyMaxSize
        self.unknownXML = unknownXML
        self.deletedObjects = deletedObjects
        self.customIcons = customIcons
        self.customIconNames = customIconNames
    }

    var resolvedMaintenanceHistoryDays: Int {
        maintenanceHistoryDays ?? Self.defaultMaintenanceHistoryDays
    }

    var resolvedHistoryMaxItems: Int {
        historyMaxItems ?? Self.defaultHistoryMaxItems
    }

    var resolvedHistoryMaxSize: Int64 {
        historyMaxSize ?? Self.defaultHistoryMaxSize
    }
}
