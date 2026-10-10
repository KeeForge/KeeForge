#if os(iOS)
import SwiftUI

/// Bottom-pinned save action for the creator screens. A navigation bar cannot
/// hold Cancel, the title, and a save label this long in most locales, so the
/// title was the part that truncated.
struct AutoFillCreatorSaveBar: View {
    let title: LocalizedStringKey
    let isSaving: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .opacity(isSaving ? 0 : 1)
                if isSaving {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isSaving)
        .accessibilityIdentifier(accessibilityIdentifier)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
#endif
