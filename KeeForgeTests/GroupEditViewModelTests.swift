import XCTest
@testable import KeeForge

@MainActor
final class GroupEditViewModelTests: XCTestCase {
    private func makeGroup(
        name: String = "Work",
        notes: String = "",
        hasNotesElement: Bool = false,
        iconID: Int = 48,
        tags: [String] = [],
        hasTagsElement: Bool = false,
        searchingEnabled: KPInheritableBool? = nil
    ) -> KPGroup {
        KPGroup(
            name: name,
            notes: notes,
            hasNotesElement: hasNotesElement,
            iconID: iconID,
            tags: tags,
            hasTagsElement: hasTagsElement,
            searchingEnabled: searchingEnabled
        )
    }

    // MARK: - Seeding

    func testEditingGroupSeedsFormStateFromTheGroup() {
        let group = makeGroup(
            name: "Work",
            notes: "  keeps its whitespace\n",
            iconID: 20,
            tags: ["work", "shared"]
        )

        let viewModel = GroupEditViewModel(editing: group, isHiddenFromAutoFill: false)

        XCTAssertEqual(viewModel.groupID, group.id)
        XCTAssertEqual(viewModel.name, "Work")
        XCTAssertEqual(viewModel.notes, "  keeps its whitespace\n")
        XCTAssertEqual(viewModel.iconID, 20)
        XCTAssertEqual(viewModel.tags, ["work", "shared"])
        XCTAssertFalse(viewModel.isHiddenFromAutoFill)
        XCTAssertFalse(viewModel.isExclusionInherited)
    }

    func testEditingGroupSeedsHiddenSwitchFromTheEffectiveExclusion() {
        let viewModel = GroupEditViewModel(
            editing: makeGroup(),
            isHiddenFromAutoFill: true,
            isExclusionInherited: true
        )

        XCTAssertTrue(viewModel.isHiddenFromAutoFill)
        XCTAssertTrue(viewModel.isExclusionInherited)
        XCTAssertFalse(viewModel.isDirty)
    }

    // MARK: - Dirty state and save gating

    func testIsDirtyTracksFormChanges() {
        let viewModel = GroupEditViewModel(editing: makeGroup(), isHiddenFromAutoFill: false)

        XCTAssertFalse(viewModel.isDirty)

        viewModel.name = "Renamed"

        XCTAssertTrue(viewModel.isDirty)
    }

    func testIsDirtyTracksNotesIconAndVisibilityChanges() {
        let notesEdit = GroupEditViewModel(editing: makeGroup(), isHiddenFromAutoFill: false)
        notesEdit.notes = "note"
        XCTAssertTrue(notesEdit.isDirty)

        let iconEdit = GroupEditViewModel(editing: makeGroup(), isHiddenFromAutoFill: false)
        iconEdit.iconID = 12
        XCTAssertTrue(iconEdit.isDirty)

        let visibilityEdit = GroupEditViewModel(editing: makeGroup(), isHiddenFromAutoFill: false)
        visibilityEdit.isHiddenFromAutoFill = true
        XCTAssertTrue(visibilityEdit.isDirty)
    }

    func testUncommittedTagTextCountsAsAChange() {
        let viewModel = GroupEditViewModel(editing: makeGroup(), isHiddenFromAutoFill: false)

        viewModel.pendingTagText = "half-typed"

        XCTAssertTrue(viewModel.isDirty)
        XCTAssertEqual(viewModel.makeDraftPayload().tags, ["half-typed"])
    }

    func testCanSaveRequiresBothANameAndAChange() {
        let viewModel = GroupEditViewModel(editing: makeGroup(), isHiddenFromAutoFill: false)

        XCTAssertFalse(viewModel.canSave)

        viewModel.name = "   "
        XCTAssertFalse(viewModel.canSave)

        viewModel.name = "  Renamed  "
        XCTAssertTrue(viewModel.canSave)
    }

    // MARK: - Payload

    func testDraftPayloadTrimsTheNameAndForwardsTheRest() {
        let viewModel = GroupEditViewModel(
            editing: makeGroup(name: "Work", notes: "old", iconID: 48, tags: ["work"]),
            isHiddenFromAutoFill: false
        )

        viewModel.name = "  Renamed  "
        viewModel.notes = "  new notes  "
        viewModel.iconID = 31

        let payload = viewModel.makeDraftPayload()

        XCTAssertEqual(payload.name, "Renamed")
        // Notes are free text: leading and trailing whitespace is the author's.
        XCTAssertEqual(payload.notes, "  new notes  ")
        XCTAssertEqual(payload.iconID, 31)
        XCTAssertEqual(payload.tags, ["work"])
    }

    func testClearedTagsReachThePayloadAsAnEmptyList() {
        let viewModel = GroupEditViewModel(
            editing: makeGroup(tags: ["work", "shared"], hasTagsElement: true),
            isHiddenFromAutoFill: false
        )

        viewModel.removeTag("work")
        viewModel.removeTag("shared")

        XCTAssertTrue(viewModel.isDirty)
        XCTAssertEqual(viewModel.makeDraftPayload().tags, [])
    }

    // MARK: - Tags

    func testCommitPendingTagSplitsOnEverySeparator() {
        let viewModel = GroupEditViewModel(editing: makeGroup(), isHiddenFromAutoFill: false)

        viewModel.pendingTagText = "alpha, beta;gamma"
        viewModel.commitPendingTag()

        XCTAssertEqual(viewModel.tags, ["alpha", "beta", "gamma"])
        XCTAssertEqual(viewModel.pendingTagText, "")
    }

    func testCommitPendingTagIgnoresATagTheGroupAlreadyCarries() {
        let viewModel = GroupEditViewModel(
            editing: makeGroup(tags: ["work"]),
            isHiddenFromAutoFill: false
        )

        viewModel.pendingTagText = "work"
        viewModel.commitPendingTag()

        XCTAssertEqual(viewModel.tags, ["work"])
    }

    func testAppendTagSuggestionCommitsTheTypedTokenFirst() {
        let viewModel = GroupEditViewModel(
            editing: makeGroup(),
            isHiddenFromAutoFill: false,
            knownTags: ["shared"]
        )

        viewModel.pendingTagText = "typed"
        viewModel.appendTagSuggestion("shared")

        XCTAssertEqual(viewModel.tags, ["typed", "shared"])
    }

    func testRemoveTagIgnoresUnknownTags() {
        let viewModel = GroupEditViewModel(
            editing: makeGroup(tags: ["work"]),
            isHiddenFromAutoFill: false
        )

        viewModel.removeTag("missing")

        XCTAssertEqual(viewModel.tags, ["work"])
        XCTAssertFalse(viewModel.isDirty)
    }

    func testTagSuggestionsExcludeAppliedAndPendingTags() {
        let viewModel = GroupEditViewModel(
            editing: makeGroup(tags: ["work"]),
            isHiddenFromAutoFill: false,
            knownTags: ["work", "shared", "archive"]
        )

        XCTAssertEqual(viewModel.tagSuggestions, ["shared", "archive"])

        viewModel.pendingTagText = "shared"

        XCTAssertEqual(viewModel.tagSuggestions, ["archive"])
    }

    func testTagSuggestionsReturnAfterAPillIsRemoved() {
        let viewModel = GroupEditViewModel(
            editing: makeGroup(tags: ["work"]),
            isHiddenFromAutoFill: false,
            knownTags: ["work", "shared"]
        )

        XCTAssertEqual(viewModel.tagSuggestions, ["shared"])

        viewModel.removeTag("work")

        XCTAssertEqual(viewModel.tagSuggestions, ["work", "shared"])
    }

    // MARK: - Search & AutoFill visibility

    func testUntouchedVisibilitySwitchReplaysTheStoredValue() {
        let cases: [(stored: KPInheritableBool?, expected: InheritableBoolPayload?)] = [
            (nil, nil),
            (.inherit, .inherit),
            (.enabled, .enabled),
            (.disabled, .disabled),
        ]

        for (stored, expected) in cases {
            let viewModel = GroupEditViewModel(
                editing: makeGroup(searchingEnabled: stored),
                isHiddenFromAutoFill: stored == .disabled
            )
            viewModel.name = "Renamed"

            XCTAssertEqual(viewModel.makeDraftPayload().searchingEnabled, expected)
        }
    }

    func testHidingWritesAnExplicitDisabled() {
        let viewModel = GroupEditViewModel(editing: makeGroup(), isHiddenFromAutoFill: false)

        viewModel.isHiddenFromAutoFill = true

        XCTAssertEqual(viewModel.makeDraftPayload().searchingEnabled, .disabled)
    }

    func testShowingWritesAnExplicitEnabledSoAnInheritedExclusionIsOverridden() {
        let viewModel = GroupEditViewModel(
            editing: makeGroup(searchingEnabled: nil),
            isHiddenFromAutoFill: true,
            isExclusionInherited: true
        )

        viewModel.isHiddenFromAutoFill = false

        XCTAssertEqual(viewModel.makeDraftPayload().searchingEnabled, .enabled)
    }

    func testFlippingTheSwitchBackRestoresTheStoredValue() {
        let viewModel = GroupEditViewModel(
            editing: makeGroup(searchingEnabled: .inherit),
            isHiddenFromAutoFill: false
        )

        viewModel.isHiddenFromAutoFill = true
        viewModel.isHiddenFromAutoFill = false

        XCTAssertFalse(viewModel.isDirty)
        XCTAssertEqual(viewModel.makeDraftPayload().searchingEnabled, .inherit)
    }

    // MARK: - Identity

    func testEachEditorHasItsOwnIdentity() {
        let group = makeGroup()
        let first = GroupEditViewModel(editing: group, isHiddenFromAutoFill: false)
        let second = GroupEditViewModel(editing: group, isHiddenFromAutoFill: false)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, first)
    }
}
