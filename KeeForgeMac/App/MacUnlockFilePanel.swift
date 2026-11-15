import AppKit
import UniformTypeIdentifiers

/// A locked database window's open panels, as sheets on that window. A sheet
/// keeps an automatic Touch ID prompt from starting behind the panel.
@MainActor
final class MacUnlockFilePanel: MacUnlockFilePicking {
    enum Request: Equatable {
        case keyFile
        case databaseFile

        var allowedContentTypes: [UTType] {
            switch self {
            case .keyFile: DocumentPickerService.keyFilePickerContentTypes
            case .databaseFile: DocumentPickerService.databasePickerContentTypes
            }
        }
    }

    /// Shows the panel and returns the chosen file; tests answer without showing anything.
    typealias Present = @MainActor (NSOpenPanel, NSWindow?) async -> URL?

    weak var window: NSWindow?
    private let present: Present

    init(present: @escaping Present = MacUnlockFilePanel.presentAsSheet) {
        self.present = present
    }

    func chooseKeyFile() async -> URL? {
        await present(Self.makePanel(for: .keyFile), window)
    }

    func locateDatabase() async -> URL? {
        await present(Self.makePanel(for: .databaseFile), window)
    }

    static func makePanel(for request: Request) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = request.allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        return panel
    }

    static func presentAsSheet(_ panel: NSOpenPanel, on window: NSWindow?) async -> URL? {
        guard let window else {
            return panel.runModal() == .OK ? panel.url : nil
        }
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
    }
}
