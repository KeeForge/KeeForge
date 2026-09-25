import SwiftUI

/// Renders the KDBX standard icon set with a stable semantic palette.
struct StandardIconView: View {
    enum Palette: CaseIterable, Hashable {
        case blue
        case brown
        case gold
        case gray
        case green
        case orange
        case pink
        case purple
        case red
        case teal

        var colors: (primary: Color, secondary: Color) {
            switch self {
            case .blue: (.blue, .cyan)
            case .brown: (.brown, .orange)
            case .gold: (.yellow, .orange)
            case .gray: (.gray, .gray.opacity(0.65))
            case .green: (.green, .mint)
            case .orange: (.orange, .yellow)
            case .pink: (.pink, .purple)
            case .purple: (.purple, .indigo)
            case .red: (.red, .orange)
            case .teal: (.teal, .cyan)
            }
        }
    }

    let iconID: Int
    var fallbackSystemName = "key.fill"
    var fallbackPalette = Palette.gold

    @Environment(\.backgroundProminence) private var backgroundProminence

    /// Every KDBX standard icon gets an intentional color instead of inheriting
    /// the app tint. The groupings are KeeForge's own semantic palette for its
    /// SF Symbol approximations, not copied artwork from another icon set.
    static let palettes: [Int: Palette] = [
        0: .gold,       // Key
        1: .blue,       // World
        2: .red,        // Warning
        3: .gray,       // NetworkServer
        4: .red,        // MarkedDirectory
        5: .blue,       // UserCommunication
        6: .gray,       // Parts
        7: .gold,       // Notepad
        8: .gray,       // WorldSocket
        9: .blue,       // Identity
        10: .blue,      // PaperReady
        11: .gray,      // Digicam
        12: .red,       // IRCommunication
        13: .gold,      // MultiKeys
        14: .gold,      // Energy
        15: .teal,      // Scanner
        16: .blue,      // WorldStar
        17: .blue,      // CDRom
        18: .blue,      // Monitor
        19: .teal,      // EMail
        20: .gray,      // Configuration
        21: .orange,    // ClipboardReady
        22: .blue,      // PaperNew
        23: .blue,      // Screen
        24: .gold,      // EnergyCareful
        25: .teal,      // EMailBox
        26: .blue,      // Disk
        27: .gray,      // Drive
        28: .purple,    // PaperQ
        29: .gold,      // TerminalEncrypted
        30: .green,     // Console
        31: .gray,      // Printer
        32: .purple,    // ProgramIcons
        33: .green,     // Run
        34: .gray,      // Settings
        35: .blue,      // WorldComputer
        36: .brown,     // Archive
        37: .green,     // Homebanking
        38: .blue,      // DriveWindows
        39: .blue,      // Clock
        40: .teal,      // EMailSearch
        41: .red,       // PaperFlag
        42: .green,     // Memory
        43: .green,     // TrashBin
        44: .gold,      // Note
        45: .red,       // Expired
        46: .blue,      // Info
        47: .brown,     // Package
        48: .blue,      // Folder
        49: .blue,      // FolderOpen
        50: .orange,    // FolderPackage
        51: .gold,      // LockOpen
        52: .gold,      // PaperLocked
        53: .green,     // Checked
        54: .gray,      // Pen
        55: .blue,      // Thumbnail
        56: .brown,     // Book
        57: .purple,    // List
        58: .gold,      // UserKey
        59: .gray,      // Tool
        60: .orange,    // Home
        61: .gold,      // Star
        62: .gray,      // Tux
        63: .pink,      // Feather
        64: .gray,      // Apple
        65: .purple,    // Wiki
        66: .green,     // Money
        67: .red,       // Certificate
        68: .blue,      // BlackBerry
    ]

    static func palette(for iconID: Int, fallback: Palette = .gold) -> Palette {
        palettes[iconID] ?? fallback
    }

    var body: some View {
        let colors = displayColors
        Image(systemName: KPEntry.systemIconName(for: iconID, fallback: fallbackSystemName))
            .symbolRenderingMode(.palette)
            .foregroundStyle(colors.primary, colors.secondary)
    }

    private var displayColors: (primary: Color, secondary: Color) {
        guard backgroundProminence != .increased else {
            return (.white, .white.opacity(0.82))
        }
        return Self.palette(for: iconID, fallback: fallbackPalette).colors
    }
}
