#if os(macOS)
import Foundation
import Observation

/// One open Mac History sheet: the entry's stored versions, the selected one as a
/// `MacEntryDetailModel(.history)` and its `EntryVersionComparison` with the current entry, and
/// Restore. It belongs to the lock cycle, content revision and selection it opened under; once any
/// of them changes it shows nothing and the presentation drops it. Its copy ticks are its own, so a
/// copy from a version never ticks the live detail behind the sheet.
@MainActor @Observable
final class MacEntryHistorySession: Identifiable {
    private struct Stamp: Equatable {
        let lockCycleID: Int
        let contentRevision: Int
        let selectedEntryID: UUID?
    }

    let entryID: UUID
    let session: DatabaseViewModel
    let copyFeedback: MacCopyFeedback
    /// `EntryHistoryVersion.index` of the selected version: storage order, not the display order.
    private(set) var selectedIndex: Int?
    private var selectedModel: MacEntryDetailModel?
    private var selectedComparison: EntryVersionComparison?
    private(set) var isClosed = false
    private var isVisible = false

    @ObservationIgnored private let stamp: Stamp
    @ObservationIgnored private let currentSession: @MainActor () -> DatabaseViewModel?
    @ObservationIgnored private let copyToClipboard: @MainActor (String) -> Void

    init(
        entryID: UUID,
        session: DatabaseViewModel,
        currentSession: @escaping @MainActor () -> DatabaseViewModel?,
        copyFeedback: MacCopyFeedback = MacCopyFeedback(),
        copy: @escaping @MainActor (String) -> Void = { ClipboardService.copy($0) }
    ) {
        self.entryID = entryID
        self.session = session
        self.currentSession = currentSession
        self.copyFeedback = copyFeedback
        copyToClipboard = copy
        stamp = Self.stamp(of: session)
        if let first = session.history(forEntryID: entryID).first {
            select(first.index)
        }
    }

    /// False once closed, locked, or the content or selection it opened under changed.
    var isCurrent: Bool {
        isClosed == false && session.state == .unlocked && session.sessionKey != nil
            && Self.stamp(of: session) == stamp && session.entry(withID: entryID) != nil
    }

    var current: KPEntry? {
        isCurrent ? session.entry(withID: entryID) : nil
    }

    /// Newest first.
    var versions: [DatabaseViewModel.EntryHistoryVersion] {
        isCurrent ? session.history(forEntryID: entryID) : []
    }

    var versionModel: MacEntryDetailModel? {
        isCurrent ? selectedModel : nil
    }

    var comparison: EntryVersionComparison? {
        isCurrent ? selectedComparison : nil
    }

    var selectedVersion: KPEntry? {
        guard let selectedIndex else { return nil }
        return versions.first { $0.index == selectedIndex }?.entry
    }

    func select(_ index: Int) {
        guard isCurrent, index != selectedIndex, let version = versions.first(where: { $0.index == index }),
              let current, let sessionKey = session.sessionKey else { return }
        selectedModel?.invalidate()
        let model = MacEntryDetailModel(source: .history(entryID: entryID, index: index), session: session,
                                        copyFeedback: copyFeedback, currentSession: currentSession,
                                        copy: copyToClipboard)
        if isVisible { model.appeared() }
        selectedModel = model
        selectedIndex = index
        let session = session
        selectedComparison = EntryVersionComparison(version: version.entry, current: current, sessionKey: sessionKey) {
            session.fieldReferenceResolution(of: $0).value
        }
    }

    func appeared() {
        isVisible = true
        selectedModel?.appeared()
    }

    func disappeared() {
        isVisible = false
        selectedModel?.disappeared()
    }

    /// Drops the version model with its reveals and the comparison; a closed session shows nothing.
    func close() {
        isClosed = true
        isVisible = false
        selectedModel?.invalidate()
        selectedModel = nil
        selectedComparison = nil
        selectedIndex = nil
        copyFeedback.clear()
    }

    // MARK: - Comparison rows

    /// The comparison field behind a version row, if the comparison covers it.
    static func comparisonField(for kind: MacEntryField.Kind) -> EntryVersionComparison.Field? {
        switch kind {
        case .username: .username
        case .password: .password
        case .website(let index): .website(index)
        case .verificationCode: .verificationCode
        case .custom(let key): .custom(key)
        case .notes: .notes
        case .passkeyRelyingParty, .passkeyUsername: nil
        }
    }

    func difference(for kind: MacEntryField.Kind) -> EntryVersionComparison.Difference? {
        guard let field = Self.comparisonField(for: kind) else { return nil }
        return comparison?.differences.first { $0.field == field }
    }

    /// Fields the current entry has and the version lacks, so the version shows no row for them.
    var differencesWithoutVersionRow: [EntryVersionComparison.Difference] {
        guard let comparison, let versionModel else { return [] }
        let rows = Set(versionModel.fields.compactMap { Self.comparisonField(for: $0.kind) })
        return comparison.differences.filter { difference in
            switch difference.field {
            case .title, .tags, .expiry: false
            default: rows.contains(difference.field) == false
            }
        }
    }

    static func label(for field: EntryVersionComparison.Field) -> String {
        switch field {
        case .title: String(localized: "Title")
        case .username: String(localized: "Username")
        case .password: String(localized: "Password")
        case .website(0): String(localized: "Website")
        case .website(let index): String(localized: "Website \(index + 1)")
        case .verificationCode: String(localized: "Verification Code")
        case .custom(let key): key
        case .notes: String(localized: "Notes")
        case .tags: String(localized: "Tags")
        case .expiry: String(localized: "Expires")
        }
    }

    /// The line under a changed value. Protected values say only that they differ.
    static func currentValueText(_ difference: EntryVersionComparison.Difference) -> String {
        switch difference.current {
        case .text(let text): String(localized: "Now: \(text)")
        case .tags(let tags): String(localized: "Now: \(tags.joined(separator: ", "))")
        case .date(let date): String(localized: "Now: \(date.formatted(date: .abbreviated, time: .shortened))")
        case .empty: String(localized: "Not set in the current version")
        case .concealed:
            difference.field == .password
                ? String(localized: "Different from the current password")
                : String(localized: "Different from the current value")
        }
    }

    // MARK: - Restore

    var canRestore: Bool {
        isCurrent && session.isReadOnly == false && selectedVersion != nil
    }

    var restoreKeepsReplacedState: Bool {
        session.restoreKeepsReplacedState(entryID: entryID)
    }

    /// Makes the selected version current (the existing restore path), closes, and saves.
    @discardableResult
    func restore() -> Task<Void, Never>? {
        guard canRestore, let selectedIndex else { return nil }
        let session = session
        do {
            try session.restoreEntryVersion(entryID: entryID, historyIndex: selectedIndex)
        } catch {
            session.presentSaveError(error)
            return nil
        }
        close()
        return Task { await session.saveHandlingError() }
    }

    private static func stamp(of session: DatabaseViewModel) -> Stamp {
        Stamp(lockCycleID: session.lockCycleID, contentRevision: session.contentRevision,
              selectedEntryID: session.workspace.selectedEntryID)
    }
}
#endif
