import AppKit
import UniformTypeIdentifiers

/// Window-bound file panels; ending a request rejects any late URL.
@MainActor
protocol MacFilePanelPresenting: MacUnlockFilePicking {
    func chooseImportFile() async -> URL?
    func saveKeyFile(suggestedName: String) async -> URL?
    func saveDatabaseCopy(suggestedName: String) async -> URL?
    func saveNewDatabase(suggestedName: String) async -> URL?
}

@MainActor
final class MacFilePanels: MacFilePanelPresenting {
    enum Request: Equatable {
        case keyFile
        case databaseFile
        case importFile

        var allowedContentTypes: [UTType] {
            switch self {
            case .keyFile: DocumentPickerService.keyFilePickerContentTypes
            case .databaseFile: DocumentPickerService.databasePickerContentTypes
            case .importFile: [.commaSeparatedText]
            }
        }
    }

    /// Shows the panel and returns the chosen file; tests answer without showing anything.
    typealias Present = @MainActor (NSOpenPanel, NSWindow?) async -> URL?

    weak var window: NSWindow?
    private let present: Present
    typealias PresentSave = @MainActor (NSSavePanel, NSWindow?) async -> URL?
    private let presentSave: PresentSave
    private var activePanel: NSSavePanel?
    private var generation = UUID()

    init(present: @escaping Present = MacFilePanels.presentAsSheet,
         presentSave: @escaping PresentSave = MacFilePanels.presentSaveAsSheet) {
        self.present = present
        self.presentSave = presentSave
    }

    func cancel() {
        generation = UUID()
        if let panel = activePanel {
            panel.sheetParent?.endSheet(panel, returnCode: .cancel)
            panel.cancel(nil)
        }
        activePanel = nil
    }

    private func choose(_ request: Request) async -> URL? {
        guard activePanel == nil else { return nil }
        let token = generation
        let panel = Self.makePanel(for: request)
        activePanel = panel
        let result = await present(panel, window.map(MacWorkspaceAlerts.topmostSheet))
        guard token == generation else { return nil }
        activePanel = nil
        return result
    }

    func chooseImportFile() async -> URL? { await choose(.importFile) }
    func saveKeyFile(suggestedName: String) async -> URL? { await save(suggestedName, types: [.data]) }
    func saveDatabaseCopy(suggestedName: String) async -> URL? {
        await save(suggestedName, types: DocumentPickerService.databasePickerContentTypes)
    }
    func saveNewDatabase(suggestedName: String) async -> URL? { await saveDatabaseCopy(suggestedName: suggestedName) }

    private func save(_ name: String, types: [UTType]) async -> URL? {
        guard activePanel == nil else { return nil }
        let token = generation
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        activePanel = panel
        let result = await presentSave(panel, window.map(MacWorkspaceAlerts.topmostSheet))
        guard token == generation else { return nil }
        activePanel = nil
        return result
    }

    static func presentSaveAsSheet(_ panel: NSSavePanel, on window: NSWindow?) async -> URL? {
        guard let window else { return panel.runModal() == .OK ? panel.url : nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
    }

    func chooseKeyFile() async -> URL? {
        await choose(.keyFile)
    }

    func locateDatabase() async -> URL? {
        await choose(.databaseFile)
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
