#if os(macOS)
import CoreGraphics
import Foundation

@MainActor
final class MacWindowRestorationStore {
    struct DatabaseWindow: Codable, Equatable {
        let databaseID: UUID
        let frame: CGRect
    }

    struct Topology: Codable, Equatable {
        var databaseWindows: [DatabaseWindow]
        var databasesWindowOpen: Bool
        var databasesWindowFrame: CGRect
        var frontmostDatabaseID: UUID?
    }

    struct RestoredDatabaseWindow: Equatable {
        let databaseID: UUID
        let frame: CGRect
        var isLocked: Bool { true }
    }

    enum ExplicitOpen: Equatable {
        case open(UUID)
        case front(UUID)
    }

    struct Plan: Equatable {
        let databaseWindows: [RestoredDatabaseWindow]
        let frontmostDatabaseID: UUID?
        let showDatabasesWindow: Bool
        let databasesWindowFrame: CGRect
        let quickLaunchDatabaseID: UUID?
        let explicitOpenRequests: [ExplicitOpen]
    }

    static let storageKey = "MacWindowRestoration"
    private let defaults: UserDefaults
    private var isTerminating = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func recordTopology(_ topology: Topology) {
        guard !isTerminating, let data = try? JSONEncoder().encode(topology) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    func beginTermination() {
        isTerminating = true
    }

    func cancelTermination() {
        isTerminating = false
    }

    static func splitViewAutosaveName(for databaseID: UUID) -> String {
        "MacDatabaseWorkspace.\(databaseID.uuidString)"
    }

    func removeSavedGeometry(for databaseID: UUID) {
        defaults.removeObject(forKey: "NSSplitView Subview Frames \(Self.splitViewAutosaveName(for: databaseID))")
    }

    func restorationPlan(
        knownDatabases: [DatabaseReference],
        screens: [CGRect],
        minimumSize: CGSize,
        defaultDatabasesWindowFrame: CGRect,
        quickLaunchDatabaseID: UUID?,
        explicitOpenRequests: [UUID]
    ) -> Plan {
        let topology = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(Topology.self, from: $0) }
        let eligibleIDs = Set(knownDatabases.filter { reference in
            switch reference.source {
            case .local: true
            case .cloud(let metadata): metadata.providerKind?.isAvailableOnCurrentPlatform == true
            }
        }.map(\.id))
        var restoredIDs: Set<UUID> = []
        let windows = (topology?.databaseWindows ?? []).compactMap { window -> RestoredDatabaseWindow? in
            guard eligibleIDs.contains(window.databaseID), restoredIDs.insert(window.databaseID).inserted else { return nil }
            return RestoredDatabaseWindow(databaseID: window.databaseID,
                frame: Self.constrainedFrame(window.frame, screens: screens, minimumSize: minimumSize))
        }
        var openedIDs = restoredIDs
        let requests = explicitOpenRequests.filter { eligibleIDs.contains($0) }.map { id in
            openedIDs.insert(id).inserted ? ExplicitOpen.open(id) : .front(id)
        }
        let explicitFront = explicitOpenRequests.last(where: { restoredIDs.contains($0) })
        let savedFront = topology?.frontmostDatabaseID.flatMap { restoredIDs.contains($0) ? $0 : nil }
        return Plan(
            databaseWindows: windows,
            frontmostDatabaseID: explicitFront ?? savedFront,
            showDatabasesWindow: topology?.databasesWindowOpen == true || windows.isEmpty,
            databasesWindowFrame: Self.constrainedFrame(topology?.databasesWindowFrame ?? defaultDatabasesWindowFrame,
                screens: screens, minimumSize: minimumSize),
            quickLaunchDatabaseID: windows.isEmpty && explicitOpenRequests.isEmpty
                ? quickLaunchDatabaseID.flatMap { eligibleIDs.contains($0) ? $0 : nil } : nil,
            explicitOpenRequests: requests
        )
    }

    private static func constrainedFrame(_ frame: CGRect, screens: [CGRect], minimumSize: CGSize) -> CGRect {
        precondition(minimumSize.width.isFinite && minimumSize.height.isFinite && minimumSize.width > 0 && minimumSize.height > 0)
        let usableScreens = screens.filter { isFinite($0) && $0.width > 0 && $0.height > 0 }
        var result = isFinite(frame) ? frame : CGRect(origin: .zero, size: minimumSize)
        result.size.width = max(result.width, minimumSize.width)
        result.size.height = max(result.height, minimumSize.height)
        guard let screen = usableScreens.min(by: { distance(result, to: $0) < distance(result, to: $1) }) else { return result }
        // A screen smaller than the minimum must still contain the whole window.
        result.size.width = min(result.width, screen.width)
        result.size.height = min(result.height, screen.height)
        result.origin.x = min(max(result.minX, screen.minX), screen.maxX - result.width)
        result.origin.y = min(max(result.minY, screen.minY), screen.maxY - result.height)
        return result
    }

    private static func isFinite(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
    }

    private static func distance(_ frame: CGRect, to screen: CGRect) -> CGFloat {
        let dx = max(screen.minX - frame.midX, 0, frame.midX - screen.maxX)
        let dy = max(screen.minY - frame.midY, 0, frame.midY - screen.maxY)
        return hypot(dx, dy)
    }
}
#endif
