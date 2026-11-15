import Foundation

/// Where a recycled item came from and when it was deleted, as its Recycle
/// Bin row says it.
struct RecycleBinOrigin: Equatable {
    /// Nil when the item names no former group, or that group is gone.
    let groupName: String?
    let deletedAt: Date?

    func summary(relativeTo now: Date = .now, locale: Locale = .current) -> String {
        let from = groupName.map { String(localized: "From \($0)") }
        let deleted = deletedAt.map { date in
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.dateTimeStyle = .named
            let when = formatter.localizedString(for: min(date, now), relativeTo: now)
            return String(localized: "Deleted \(when)")
        }
        return [from, deleted].compactMap { $0 }.joined(separator: " · ")
    }
}
