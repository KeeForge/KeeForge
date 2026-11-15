#if os(macOS)
import AppKit
import Observation
import SwiftUI
import XCTest
@testable import KeeForge

/// The panel is built but never ordered front: `present` only records it.
@MainActor
final class MacPasswordGeneratorPanelControllerTests: XCTestCase {
    private var presented: [NSPanel] = []
    private var copied: [String] = []
    private var modelsMade = 0
    private let sessions = UnlockedSessions()

    func testShowBuildsOneUtilityPanelWithTheCaptureSettingAppliedAtCreation() throws {
        for blocksCapture in [true, false] {
            let controller = makeController(blockCapture: blocksCapture)
            controller.show()

            let panel = try XCTUnwrap(controller.panel)
            XCTAssertTrue(presented.last === panel)
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(panel.sharingType, blocksCapture ? .none : .readOnly,
                           "Applied before the panel is first shown, not left to the key-window sweep")
            XCTAssertEqual(panel.styleMask, [.titled, .closable, .utilityWindow])
            XCTAssertTrue(panel.isFloatingPanel)
            XCTAssertFalse(panel.isReleasedWhenClosed)
            XCTAssertEqual(panel.title, String(localized: "Password Generator"))
            XCTAssertEqual(panel.accessibilityIdentifier(), "password-generator.panel")
            XCTAssertTrue(panel.contentView is NSHostingView<ModifiedContent<MacPasswordGeneratorPanelView, MacHostingAppearance>>)
            XCTAssertEqual(controller.model?.suggestion, "suggestion-\(modelsMade)")

            let model = controller.model
            controller.show()
            XCTAssertTrue(controller.panel === panel, "One panel per app: showing again brings it front")
            XCTAssertTrue(controller.model === model, "and keeps its suggestion")
            XCTAssertTrue(presented.last === panel)
            controller.close()
        }
    }

    func testNothingOpensWhileNoDatabaseIsUnlocked() {
        sessions.isUnlocked = false
        let controller = makeController()
        controller.show()
        XCTAssertNil(controller.panel)
        XCTAssertNil(controller.model)
        XCTAssertTrue(presented.isEmpty)
        XCTAssertEqual(modelsMade, 0)
    }

    func testEscapeTheCloseButtonAndCloseDropThePanelAndTheSuggestion() throws {
        let controller = makeController()
        let triggers: [(String, @MainActor (MacPasswordGeneratorPanel) -> Void)] = [
            ("Escape", { $0.cancelOperation(nil) }),
            ("the close button", { $0.close() }),
            ("close()", { _ in controller.close() }),
        ]
        for (name, trigger) in triggers {
            controller.show()
            let panel = try XCTUnwrap(controller.panel, name)
            let model = try XCTUnwrap(controller.model, name)
            trigger(panel)
            XCTAssertNil(controller.panel, name)
            XCTAssertNil(controller.model, name)
            XCTAssertNil(panel.contentView, name)
            XCTAssertEqual(model.suggestion, "", "\(name) drops the suggestion")
        }
        controller.show()
        XCTAssertEqual(modelsMade, 4, "Each opening starts from a new model with the remembered options")
    }

    func testThePanelClosesWhenTheLastUnlockedDatabaseLocks() async throws {
        let controller = makeController()
        controller.show()
        let model = try XCTUnwrap(controller.model)

        sessions.isUnlocked = false
        for _ in 0..<50 where controller.panel != nil { await Task.yield() }
        XCTAssertNil(controller.panel)
        XCTAssertNil(controller.model)
        XCTAssertEqual(model.suggestion, "")

        sessions.isUnlocked = true
        controller.show()
        XCTAssertNotNil(controller.panel, "It opens again once a database is unlocked")
        controller.close()
    }

    func testCopyGoesThroughTheModelsClipboardPath() throws {
        let controller = makeController()
        controller.show()
        let panel = try XCTUnwrap(controller.panel)
        let view = try XCTUnwrap(panel.contentView as? NSHostingView<ModifiedContent<MacPasswordGeneratorPanelView, MacHostingAppearance>>)

        view.rootView.content.model.copySuggestion()
        XCTAssertEqual(copied, ["suggestion-1"])
        controller.close()
    }

    // MARK: - Support

    private func makeController(blockCapture: Bool = false) -> MacPasswordGeneratorPanelController {
        let sessions = sessions
        return MacPasswordGeneratorPanelController(
            hasUnlockedSession: { sessions.isUnlocked },
            blockCapture: { blockCapture },
            present: { [weak self] in self?.presented.append($0) },
            makeModel: { [weak self] in
                guard let self else { return PasswordGeneratorModel() }
                modelsMade += 1
                let number = modelsMade
                return PasswordGeneratorModel(loadOptions: { PasswordGenerator.Options() }, saveOptions: { _ in },
                                              generate: { _ in "suggestion-\(number)" },
                                              copy: { [weak self] in self?.copied.append($0) })
            }
        )
    }
}

@MainActor @Observable
private final class UnlockedSessions {
    var isUnlocked = true
}
#endif
