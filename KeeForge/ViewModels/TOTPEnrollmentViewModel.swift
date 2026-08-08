import Foundation
import Observation

/// Decision logic for the incoming `otpauth://` enrollment flow: which live
/// entries can receive the code, which groups can host a new entry, and how
/// a new entry is prefilled. Built from a tree snapshot so the destination
/// sheet stays thin and the logic stays unit-testable.
@MainActor @Observable
final class TOTPEnrollmentViewModel {
    struct EntryCandidate: Identifiable, Equatable, Sendable {
        let id: UUID
        let title: String
        let username: String
        let url: String
        /// Ancestor group names below the visible root joined with " / ",
        /// `nil` for entries sitting directly under it — same display rule as
        /// `DatabaseViewModel.folderPath(forEntryID:)`.
        let folderPath: String?
        let hasTOTP: Bool
    }

    struct GroupOption: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
        let depth: Int
    }

    let uri: OTPAuthURI
    /// Local to this sheet on purpose: filtering here must not disturb the
    /// session's global `searchText`.
    var searchText = ""

    /// Live entries in tree order; recycle-bin subtrees contribute nothing.
    private let entryCandidates: [EntryCandidate]
    /// All non-recycle-bin groups, visible root first, in tree order with
    /// depth for indentation.
    let groupOptions: [GroupOption]

    init(uri: OTPAuthURI, visibleRoot: KPGroup?, recycleBinGroupID: UUID?) {
        self.uri = uri

        var candidates: [EntryCandidate] = []
        var groups: [GroupOption] = []
        if let visibleRoot {
            Self.collect(
                from: visibleRoot,
                depth: 0,
                path: [],
                recycleBinGroupID: recycleBinGroupID,
                candidates: &candidates,
                groups: &groups
            )
        }
        entryCandidates = candidates
        groupOptions = groups
    }

    convenience init(uri: OTPAuthURI, database: DatabaseViewModel) {
        self.init(
            uri: uri,
            visibleRoot: database.visibleRootGroup,
            recycleBinGroupID: database.currentRootGroup?.recycleBinUUID
        )
    }

    var summaryTitle: String {
        uri.issuer ?? uri.accountName ?? String(localized: "Verification code")
    }

    /// The account name, when the issuer already occupies the title line.
    var summarySubtitle: String? {
        uri.issuer != nil ? uri.accountName : nil
    }

    var prefilledTitle: String {
        uri.issuer ?? uri.accountName ?? ""
    }

    var prefilledUsername: String {
        uri.accountName ?? ""
    }

    /// Whether an empty `filteredEntryCandidates` means "nothing matched"
    /// rather than "this database has no entries".
    var hasActiveSearch: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var filteredEntryCandidates: [EntryCandidate] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return entryCandidates }
        return entryCandidates.filter { candidate in
            candidate.title.localizedCaseInsensitiveContains(query)
                || candidate.username.localizedCaseInsensitiveContains(query)
                || candidate.url.localizedCaseInsensitiveContains(query)
        }
    }

    /// Attaching over an existing verification code destroys it on save, so
    /// only that case needs the destructive confirmation.
    func requiresReplaceConfirmation(_ candidate: EntryCandidate) -> Bool {
        candidate.hasTOTP
    }

    private static func collect(
        from group: KPGroup,
        depth: Int,
        path: [String],
        recycleBinGroupID: UUID?,
        candidates: inout [EntryCandidate],
        groups: inout [GroupOption]
    ) {
        guard group.id != recycleBinGroupID else { return }

        groups.append(GroupOption(id: group.id, name: group.name, depth: depth))
        for entry in group.entries {
            candidates.append(
                EntryCandidate(
                    id: entry.id,
                    title: entry.title,
                    username: entry.username,
                    url: entry.url,
                    folderPath: path.isEmpty ? nil : path.joined(separator: " / "),
                    hasTOTP: entry.hasTOTP
                )
            )
        }
        for subgroup in group.groups {
            collect(
                from: subgroup,
                depth: depth + 1,
                path: path + [subgroup.name],
                recycleBinGroupID: recycleBinGroupID,
                candidates: &candidates,
                groups: &groups
            )
        }
    }
}
