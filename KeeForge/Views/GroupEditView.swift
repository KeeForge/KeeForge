import SwiftUI

/// The group editor: name, icon, tags, notes and Search & AutoFill visibility in
/// one form, applied as a single `updateGroup` edit.
///
/// A plain `Form` with no `NavigationStack` of its own — presenters supply one
/// (a sheet on macOS, a navigation push on iOS), the way `EntryEditView` is
/// presented.
struct GroupEditView: View {
    @State private var formViewModel: GroupEditViewModel
    @Bindable var databaseViewModel: DatabaseViewModel
    let onComplete: () -> Void

    @State private var showDiscardConfirmation = false
    @State private var isShowingIconPicker = false
    @State private var editingErrorMessage: String?
    @State private var isSubmitting = false

    private var isSavingInProgress: Bool {
        isSubmitting || databaseViewModel.isSaving
    }

    init(
        formViewModel: GroupEditViewModel,
        databaseViewModel: DatabaseViewModel,
        onComplete: @escaping () -> Void = {}
    ) {
        _formViewModel = State(initialValue: formViewModel)
        self.databaseViewModel = databaseViewModel
        self.onComplete = onComplete
    }

    var body: some View {
        Form {
            Section("Basics") {
                fieldRow("Name") {
                    TextField("Group Name", text: $formViewModel.name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("group-edit.name-field")
                }

                iconRow

                fieldRow("Tags") {
                    appliedTagStrip

                    // Single-line on purpose: Return has to submit the tag
                    // rather than insert a newline, matching the entry editor.
                    TextField("Add a tag", text: $formViewModel.pendingTagText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { formViewModel.commitPendingTag() }
                        .accessibilityIdentifier("group-edit.tags-field")

                    tagSuggestionStrip
                }
            }

            Section("Notes") {
                TextEditor(text: $formViewModel.notes)
                    .frame(minHeight: 140)
                    .accessibilityIdentifier("group-edit.notes-field")
            }

            Section("Search & AutoFill") {
                Toggle("Hide from Search & AutoFill", isOn: $formViewModel.isHiddenFromAutoFill)
                    .accessibilityIdentifier("group-edit.autofill-toggle")

                if formViewModel.isExclusionInherited {
                    Text("A parent group is hidden from Search & AutoFill. Turn this off to show this group anyway.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Edit Group")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .disabled(isSavingInProgress)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    cancelTapped()
                }
                .disabled(isSavingInProgress)
                .accessibilityIdentifier("group-edit.cancel")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveTapped()
                }
                .disabled(formViewModel.canSave == false || isSavingInProgress)
                .accessibilityIdentifier("group-edit.save")
            }
        }
        .overlay {
            if isSubmitting && databaseViewModel.isSaving == false {
                ZStack {
                    Color.black.opacity(0.14)
                        .ignoresSafeArea()

                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Saving changes...")
                            .font(.headline)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.regularMaterial)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 20, y: 8)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Saving changes")
                .accessibilityIdentifier("group-edit.saving-overlay")
            }
        }
        .sheet(isPresented: $isShowingIconPicker) {
            GroupIconPickerView(
                groupName: formViewModel.trimmedName,
                selectedIconID: formViewModel.iconID
            ) { iconID in
                formViewModel.iconID = iconID
            }
        }
        .alert("Discard changes?", isPresented: $showDiscardConfirmation) {
            Button("Discard Changes", role: .destructive) {
                onComplete()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your group changes haven't been saved to this database draft yet.")
        }
        .alert(
            "Couldn’t Update Group",
            isPresented: Binding(
                get: { editingErrorMessage != nil },
                set: { isPresented in
                    if isPresented == false {
                        editingErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(editingErrorMessage ?? "")
        }
    }

    /// The group's standard KDBX icon, presenting the shared picker sheet. A
    /// custom icon is deliberately not previewed here: the payload only carries
    /// a standard `iconID`, and the draft layer keeps the custom icon untouched
    /// unless the user actually picks a different standard one.
    private var iconRow: some View {
        Button {
            isShowingIconPicker = true
        } label: {
            HStack {
                Text("Icon")
                Spacer(minLength: 8)
                Image(systemName: KPEntry.systemIconName(for: formViewModel.iconID, fallback: "folder.fill"))
                    .foregroundStyle(.tint)
                Image(systemName: "chevron.forward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("group-edit.icon-button")
    }

    /// The tags this group already carries, one removable pill each. Nothing
    /// renders before the first tag lands, so an untagged group opens on a plain
    /// field rather than an empty container.
    ///
    /// Declared an accessibility container so the pills keep their own
    /// identifiers instead of inheriting the strip's (see `README.md`).
    @ViewBuilder
    private var appliedTagStrip: some View {
        if formViewModel.tags.isEmpty == false {
            FlowLayout(spacing: 6) {
                ForEach(Array(formViewModel.tags.enumerated()), id: \.offset) { index, tag in
                    appliedTagChip(tag, fallbackIndex: index)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("group-edit.tags")
        }
    }

    private func appliedTagChip(_ tag: String, fallbackIndex: Int) -> some View {
        Button {
            formViewModel.removeTag(tag)
        } label: {
            TagCapsule(tag: tag, trailingSystemImage: "xmark")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Remove tag \(tag)"))
        .accessibilityIdentifier(
            "group-edit.tag.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: fallbackIndex))"
        )
    }

    /// The database's other tags, one tap each. Nothing at all renders when
    /// there is nothing left to offer.
    @ViewBuilder
    private var tagSuggestionStrip: some View {
        let suggestions = formViewModel.tagSuggestions
        if suggestions.isEmpty == false {
            FlowLayout(spacing: 6) {
                // Enumerated for the identifier fallback index, which is what
                // gives an emoji-only tag — one that normalizes to nothing — a
                // usable identifier.
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, tag in
                    tagSuggestionChip(tag, fallbackIndex: index)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("group-edit.tag-suggestions")
        }
    }

    private func tagSuggestionChip(_ tag: String, fallbackIndex: Int) -> some View {
        Button {
            formViewModel.appendTagSuggestion(tag)
        } label: {
            TagCapsule(tag: tag, systemImage: "plus")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add tag \(tag)"))
        .accessibilityIdentifier(
            "group-edit.tag-suggestion.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: fallbackIndex))"
        )
    }

    private func fieldRow<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            content()
        }
        .padding(.vertical, 2)
    }

    private func cancelTapped() {
        if formViewModel.isDirty {
            showDiscardConfirmation = true
        } else {
            onComplete()
        }
    }

    private func saveTapped() {
        do {
            try databaseViewModel.updateGroup(
                groupID: formViewModel.groupID,
                draft: formViewModel.makeDraftPayload()
            )

            isSubmitting = true
            Task { @MainActor in
                await databaseViewModel.saveHandlingError()
                isSubmitting = false
                if let saveError = databaseViewModel.saveError {
                    editingErrorMessage = saveError.localizedDescription
                    databaseViewModel.clearSaveError()
                } else {
                    onComplete()
                }
            }
        } catch {
            editingErrorMessage = error.localizedDescription
        }
    }
}
