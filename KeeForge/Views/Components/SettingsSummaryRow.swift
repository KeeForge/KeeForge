import SwiftUI

/// The label of a settings hub row: an icon, a title, and one line saying what
/// is currently set behind it.
struct SettingsSummaryRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    var summary: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)

                if let summary, summary.isEmpty == false {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(Self.summaryLineLimit(for: dynamicTypeSize))
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    /// Two lines keep the rows even at standard sizes; at accessibility sizes
    /// two lines no longer hold a whole summary, so it wraps in full.
    static func summaryLineLimit(for dynamicTypeSize: DynamicTypeSize) -> Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : 2
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
