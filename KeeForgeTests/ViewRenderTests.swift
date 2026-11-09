#if os(iOS)
import KDBXKit
import SwiftUI
import XCTest
@testable import KeeForge

/// Renders views in each of their states to PNGs for visual review, in the
/// test run's language. Skipped unless `VIEW_RENDER_DIR` names an output
/// directory; `scripts/render-views.sh` sets it and runs each shipped language.
@MainActor
final class ViewRenderTests: XCTestCase {
    private var outputDirectory: URL!
    private var language: String!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["VIEW_RENDER_DIR"], path.isEmpty == false else {
            throw XCTSkip("Set VIEW_RENDER_DIR to render views.")
        }
        language = Bundle.main.preferredLocalizations.first ?? "en"
        outputDirectory = URL(fileURLWithPath: path).appendingPathComponent(language)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    // MARK: Database list rows

    func testDatabaseListRows() throws {
        let listViewModel = DatabaseListViewModel()
        let states: [(String, DatabaseReference, DatabaseRowStatus)] = [
            ("Local, opened 3 days ago", reference("Personal", lastOpenedAt: .now.addingTimeInterval(-3 * 86_400)), status()),
            ("Local, never opened", reference("Archive"), status()),
            ("Quick Launch", reference("Work", isQuickLaunch: true, lastOpenedAt: .now.addingTimeInterval(-3_600)), status()),
            ("Read-only", reference("Family", isReadOnly: true, lastOpenedAt: .now.addingTimeInterval(-86_400)), status()),
            ("Cloud, synced 13 min ago", reference("test", provider: .oneDrive, lastSyncedAt: .now.addingTimeInterval(-13 * 60)), status(cloud: .some(nil))),
            ("Cloud, sync older than 24h", reference("main", provider: .dropbox, lastSyncedAt: .now.addingTimeInterval(-2 * 86_400)), status(cloud: CloudSyncMetadata.staleWarning)),
            ("Cloud, disconnected", reference("Team", provider: .ftp, lastSyncedAt: .now.addingTimeInterval(-600)), status(cloud: String(localized: "Disconnected"))),
            ("Upload pending (3)", reference("Shared", provider: .webDAV, lastSyncedAt: .now.addingTimeInterval(-600)), status(pending: 3, cloud: .some(nil))),
            ("Upload conflicts (2)", reference("Shared", provider: .webDAV, lastSyncedAt: .now.addingTimeInterval(-600)), status(pending: 2, conflicts: 2, cloud: .some(nil))),
            ("File unavailable", reference("Old Laptop"), status(accessIssue: true)),
            ("Cloud cache unavailable", reference("Travel", provider: .dropbox, lastSyncedAt: .now.addingTimeInterval(-600)), status(accessIssue: true, cloud: .some(nil))),
            ("Removed from KeeForge folder", reference("Imported"), status(documentsFileMissing: true)),
            ("Usage stats off: no last synced", reference("Hidden", provider: .dropbox, lastSyncedAt: .now.addingTimeInterval(-600)), status(cloud: .some(nil))),
            ("All badges, long name", reference("Household Finances and Insurance", isQuickLaunch: true, isReadOnly: true, provider: .dropbox, lastSyncedAt: .now.addingTimeInterval(-600)), status(pending: 12, cloud: .some(nil))),
        ]

        let rows = states.map { caption, reference, status in
            let showsUsageStats = caption.hasPrefix("Usage stats off") == false
            return RenderedState(caption: caption) {
                DatabaseListRow(
                    reference: reference,
                    status: status,
                    lastOpenedDescription: listViewModel.lastOpenedDescription(for: reference, showsUsageStats: showsUsageStats),
                    showsUsageStats: showsUsageStats
                )
            }
        }
        try render(rows, named: "database-rows")
    }

    // MARK: Unlock failures

    func testUnlockFailureCards() throws {
        let states: [(String, DatabaseOpenFailure)] = [
            ("Wrong password", .classify(KDBXCrypto.CryptoError.hmacMismatch, isCloudBacked: false)),
            ("Wrong password, YubiKey possible", .classify(KDBXCrypto.CryptoError.hmacMismatch, isCloudBacked: false, hardwareKeyContext: .available)),
            ("Wrong password, YubiKey configured", .classify(KDBXCrypto.CryptoError.hmacMismatch, isCloudBacked: false, hardwareKeyContext: .configured)),
            ("Key file hash mismatch", .classify(KeyFileProcessor.KeyFileError.xmlHashMismatch, isCloudBacked: false)),
        ]
        let cards = states.map { caption, failure in
            RenderedState(caption: caption, card: false) {
                UnlockFailureCard(failure: failure, onSendFeedback: {})
            }
        }
        try render(cards, named: "unlock-failure-cards")
    }

    // MARK: Sheets

    func testNewDatabaseSheet() throws {
        let empty = DatabaseCreationViewModel()

        let filled = DatabaseCreationViewModel()
        filled.databaseName = "Family"
        filled.password = "correct-Horse-battery-staple-42"
        filled.confirmPassword = filled.password
        filled.cipher = .chacha20

        let weak = DatabaseCreationViewModel()
        weak.databaseName = "Team: Shared/Keys"
        weak.password = "hunter2"
        weak.destinationChoice = DatabaseCreationDestinationChoice.availableChoices.last ?? .files
        let keyFile = FileManager.default.temporaryDirectory.appendingPathComponent("Family.keyx")
        try Data("render".utf8).write(to: keyFile)
        try weak.selectKeyFile(url: keyFile)

        try renderScreens([
            ("Filled", AnyView(DatabaseCreationView(viewModel: filled, onCreated: { _ in }))),
            ("Empty", AnyView(DatabaseCreationView(viewModel: empty, onCreated: { _ in }))),
            ("Weak password, key file, cloud", AnyView(DatabaseCreationView(viewModel: weak, onCreated: { _ in }))),
        ], named: "new-database")
    }

    func testPasswordGeneratorSheet() throws {
        let saved = SettingsService.passwordGeneratorOptions
        defer { SettingsService.passwordGeneratorOptions = saved }

        var states: [(String, AnyView)] = []
        SettingsService.passwordGeneratorOptions = PasswordGenerator.Options(length: 24)
        states.append(("Password, 24 characters", AnyView(PasswordGeneratorSheet(onUse: { _ in }))))
        SettingsService.passwordGeneratorOptions = PasswordGenerator.Options(length: PasswordGenerator.lengthRange.upperBound)
        states.append(("Password, maximum length", AnyView(PasswordGeneratorSheet(onUse: { _ in }))))
        try renderScreens(states, named: "password-generator")

        SettingsService.passwordGeneratorOptions = PasswordGenerator.Options(mode: .passphrase)
        try renderScreens([("Passphrase", AnyView(PasswordGeneratorSheet(onUse: { _ in })))], named: "password-generator-passphrase")
    }

    /// Whole screens need a real window: `ImageRenderer` draws Form, Toggle,
    /// Slider and Picker as placeholders.
    private func renderScreens(_ states: [(String, AnyView)], named name: String) throws {
        let columns: [(size: CGSize, type: DynamicTypeSize, label: String)] = [
            (CGSize(width: 375, height: 1400), .large, "375pt"),
            (CGSize(width: 440, height: 1400), .large, "440pt"),
            (CGSize(width: 440, height: 2400), .accessibility2, "440pt AX2"),
        ]
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "The test host has no window scene"
        )
        for (stateIndex, state) in states.enumerated() {
            var shots: [UIImage] = []
            for column in columns {
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(origin: .zero, size: column.size)
                window.windowLevel = .alert + 1
                window.rootViewController = UIHostingController(
                    rootView: state.1
                        .dynamicTypeSize(column.type)
                        .environment(\.locale, Locale(identifier: language))
                )
                window.isHidden = false
                RunLoop.main.run(until: Date().addingTimeInterval(1.0))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                window.isHidden = true
                shots.append(image)
            }
            let gap: CGFloat = 24
            let width = columns.reduce(0) { $0 + $1.size.width } + gap * CGFloat(columns.count - 1)
            let height = columns.map(\.size.height).max() ?? 0
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let sheet = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
                UIColor.darkGray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                var x: CGFloat = 0
                for (index, shot) in shots.enumerated() {
                    shot.draw(at: CGPoint(x: x, y: 0))
                    x += columns[index].size.width + gap
                }
            }
            let data = try XCTUnwrap(sheet.pngData())
            let suffix = states.count > 1 ? "-\(stateIndex + 1)" : ""
            try data.write(to: outputDirectory.appendingPathComponent("\(name)\(suffix).png"))
            print("render \(name)\(suffix): \(state.0)")
        }
    }

    // MARK: Rendering

    private struct RenderedState {
        let caption: String
        var card = true
        let content: AnyView

        init(caption: String, card: Bool = true, @ViewBuilder content: () -> some View) {
            self.caption = caption
            self.card = card
            self.content = AnyView(content())
        }
    }

    /// One column per width and text size, every state stacked in each.
    private func render(_ states: [RenderedState], named name: String) throws {
        let columns: [(width: CGFloat, size: DynamicTypeSize, label: String)] = [
            (375, .large, "375pt · default text"),
            (440, .large, "440pt · default text"),
            (440, .accessibility2, "440pt · AX2 text"),
        ]
        let language: String = language
        let locale = Locale(identifier: language)
        let sheet = HStack(alignment: .top, spacing: 24) {
            ForEach(columns.indices, id: \.self) { index in
                let column = columns[index]
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: "\(language) · \(column.label)")
                        .font(.system(size: 13, weight: .semibold).monospaced())
                        .foregroundStyle(.secondary)
                    ForEach(states.indices, id: \.self) { stateIndex in
                        let state = states[stateIndex]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: state.caption)
                                .font(.system(size: 11).monospaced())
                                .foregroundStyle(.secondary)
                            Group {
                                if state.card {
                                    state.content
                                        .padding(.horizontal, Theme.Spacing.side)
                                        .padding(.vertical, 11)
                                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                                } else {
                                    state.content
                                }
                            }
                            .dynamicTypeSize(column.size)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .frame(width: column.width, alignment: .topLeading)
            }
        }
        .padding(.vertical, 16)
        .background(Color(.systemGroupedBackground))
        .environment(\.locale, locale)
        .tint(Color.accentColor)

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "Rendering \(name) produced no image")
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }

    // MARK: Fixtures

    private func reference(
        _ name: String,
        isQuickLaunch: Bool = false,
        isReadOnly: Bool = false,
        lastOpenedAt: Date? = nil,
        provider: CloudProviderKind? = nil,
        lastSyncedAt: Date? = nil
    ) -> DatabaseReference {
        let filename = "\(name).kdbx"
        var reference = DatabaseReference(
            id: UUID(),
            nickname: name == "Personal" ? nil : name,
            filename: name == "Personal" ? "Passwords.kdbx" : filename,
            bookmarkData: nil,
            keyFileBookmarkData: nil,
            keyFileFilename: nil,
            isQuickLaunch: isQuickLaunch,
            lastOpenedAt: lastOpenedAt,
            addedAt: Date(timeIntervalSince1970: 0),
            colorTag: nil,
            legacyKeychainFilename: nil,
            source: provider.map {
                .cloud(
                    CloudSyncMetadata(
                        provider: $0.rawValue,
                        accountId: "account",
                        fileId: "/\(filename)",
                        displayPath: "/\(filename)",
                        remoteContentHash: nil,
                        remoteModifiedAt: nil,
                        lastSyncedAt: lastSyncedAt,
                        lastSyncIssue: nil
                    )
                )
            } ?? .local
        )
        reference.isReadOnly = isReadOnly
        return reference
    }

    /// `cloud` is the row's cloud warning; nil for a healthy cloud row.
    private func status(
        pending: Int = 0,
        conflicts: Int = 0,
        accessIssue: Bool = false,
        documentsFileMissing: Bool = false,
        cloud: String?? = .none
    ) -> DatabaseRowStatus {
        DatabaseRowStatus(
            hasStoredKey: false,
            hasAccessIssue: accessIssue,
            cloudState: cloud.map {
                CloudRowState(providerName: "", isConnected: true, warningText: $0, displayPath: "", accountLabel: "")
            },
            pendingUploadCount: pending,
            pendingUploadConflictCount: conflicts,
            isDocumentsFileMissing: documentsFileMissing
        )
    }
}

private extension CloudSyncMetadata {
    /// The real stale-sync wording, from a sync two days old.
    static var staleWarning: String? {
        CloudSyncMetadata(
            provider: CloudProviderKind.dropbox.rawValue,
            accountId: "",
            fileId: "",
            displayPath: "",
            remoteContentHash: nil,
            remoteModifiedAt: nil,
            lastSyncedAt: .now.addingTimeInterval(-2 * 86_400),
            lastSyncIssue: nil
        ).warningText(isAuthenticated: true)
    }
}
#endif
