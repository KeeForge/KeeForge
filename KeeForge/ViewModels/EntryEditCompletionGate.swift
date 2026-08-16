import Foundation

/// How the entry editor ended. Saved and cancelled are distinct on purpose:
/// most presenters dismiss either way, but the TOTP enrollment flow returns
/// to its destination list on cancel and finishes only on save.
enum EntryEditCompletion: Equatable, Sendable {
    case saved
    case cancelled
    case deleted
}

/// Decides when the entry editor may report a save or delete completion.
///
/// Reporting it while a save conflict is on screen races the root conflict
/// alert: UIKit presents that alert from the editor itself, so the editor's
/// dismissal and the alert's presentation land in one transaction and the
/// dismissal is dropped. The gate holds the completion instead and releases
/// it once the conflict has settled — no conflict, no merge summary/failure
/// alert still up (those present from the editor too), and a clean draft,
/// meaning the conflict ended in a write that landed.
struct EntryEditCompletionGate: Equatable, Sendable {
    private(set) var heldCompletion: EntryEditCompletion?

    /// A save or delete finished. Returns the completion to report now, or
    /// `nil` when a conflict holds it for `conflictSettled(_:)` to release.
    mutating func finish(_ completion: EntryEditCompletion, hasSaveConflict: Bool) -> EntryEditCompletion? {
        guard hasSaveConflict == false else {
            heldCompletion = completion
            return nil
        }
        heldCompletion = nil
        return completion
    }

    /// The conflict state changed. Returns the held completion once settled,
    /// exactly once.
    mutating func conflictSettled(_ settled: Bool) -> EntryEditCompletion? {
        guard settled, let completion = heldCompletion else { return nil }
        heldCompletion = nil
        return completion
    }

    /// The settled predicate: a conflict cleared ahead of a fresh write (Save
    /// again, applying another edit) leaves the draft dirty and so does not
    /// count — the editor stays open for that write's own outcome.
    static func isSettled(hasSaveConflict: Bool, isPresentingMergeResult: Bool, isDirty: Bool) -> Bool {
        hasSaveConflict == false && isPresentingMergeResult == false && isDirty == false
    }
}
