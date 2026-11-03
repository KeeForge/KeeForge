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

    static var isPresentationRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    @State private var result = "none"
    private let possibleEntries: [KPEntry]
    private let searchEntries: [KPEntry]

    init() {
        func entry(_ title: String, url: String) -> KPEntry {
            KPEntry(title: title, username: "alex", url: url)
        }
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
                entries: [],
                searchEntries: searchEntries,
                possibleEntries: possibleEntries,
                onSelect: { result = "selected \($0.title)" },
                onSelectPossible: { result = "selected \($0.title)" },
                urlAddition: AutoFillURLAddition(host: "login.example.com", url: "https://login.example.com") {
                    result = "added https://login.example.com to \($0.title)"
                },
                onCancel: { result = "cancelled" }
            )
            Text(verbatim: result)
                .font(.caption.monospaced())
                .padding(8)
                .accessibilityIdentifier("autofill-harness.result")
        }
    }
}
#endif
