import SwiftUI

/// The label of a settings hub row: an icon, a title, and one line saying what
/// is currently set behind it.
struct SettingsSummaryRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    var summary: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)

                if let summary, summary.isEmpty == false {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

enum SettingsSummaryText {
    static func joined(_ parts: [String?]) -> String {
        parts
            .compactMap { $0 }
            .filter { $0.isEmpty == false }
            .joined(separator: " · ")
    }
}
