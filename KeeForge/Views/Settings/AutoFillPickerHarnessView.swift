#if DEBUG
import SwiftUI

/// DEBUG-only host for the AutoFill extension's picker, so UI tests can drive
/// `AutoFillSearchView` without Safari's AutoFill sheet. Launched with
/// `-autofill-picker-harness`, it replaces the app root with the picker for a
/// request from `login.example.com` over in-memory entries, and reports the
/// picker's callbacks in `autofill-harness.result`. The coordinator logic
/// behind those callbacks is covered by `CredentialProviderCoordinatorTests`.
struct AutoFillPickerHarnessView: View {
    static let launchArgument = "-autofill-picker-harness"

    /// Pre-fills the search, as the coordinator does with a request's domain.
    static let initialSearchEnvironmentKey = "UI_TEST_AUTOFILL_HARNESS_SEARCH"
    /// App Store capture: realistic entries for a github.com request, without the result label.
    static let storeArgument = "-autofill-picker-store"

    static var isPresentationRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    private let isStore = ProcessInfo.processInfo.arguments.contains(storeArgument)

    @State private var result = "none"
    private let possibleEntries: [KPEntry]
    private let searchEntries: [KPEntry]
    private let exactEntries: [KPEntry]

    init() {
        func entry(_ title: String, url: String) -> KPEntry {
            KPEntry(title: title, username: "alex", url: url)
        }
        if ProcessInfo.processInfo.arguments.contains(Self.storeArgument) {
            let personal = KPEntry(title: "GitHub", username: "alexrivers", url: "https://github.com", iconID: 1)
            let work = KPEntry(title: "GitHub (Work)", username: "alex@northwind.dev", url: "https://github.com/login", iconID: 1)
            possibleEntries = []
            searchEntries = [personal, work]
            exactEntries = [personal, work]
            return
        }
        exactEntries = []
        let sibling = entry("Example Account", url: "https://www.example.com")
        possibleEntries = [sibling]
        searchEntries = [
            sibling,
            entry("Bank", url: "https://bank.test"),
            entry("Notes Only", url: ""),
            entry("Example Login", url: "https://login.example.com/signin"),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            AutoFillSearchView(
                entries: exactEntries,
                searchEntries: searchEntries,
                possibleEntries: possibleEntries,
                initialSearchText: ProcessInfo.processInfo.environment[Self.initialSearchEnvironmentKey] ?? "",
                sharedCopyDate: Date(timeIntervalSinceReferenceDate: 0),
                onCreateEntry: { result = "create" },
                onSelect: { result = "selected \($0.title)" },
                onSelectPossible: { result = "selected \($0.title)" },
                urlAddition: isStore ? nil : AutoFillURLAddition(host: "login.example.com", url: "https://login.example.com") {
                    result = "added https://login.example.com to \($0.title)"
                },
                onCancel: { result = "cancelled" }
            )
            if !isStore {
                Text(verbatim: result)
                    .font(.caption.monospaced())
                    .padding(8)
                    .accessibilityIdentifier("autofill-harness.result")
            }
        }
    }
}
#endif
