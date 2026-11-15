import AppKit
import SwiftUI

struct MacGroupEditorView: View {
    @Bindable var form: GroupEditViewModel
    let database: DatabaseViewModel
    @Bindable var coordinator: DatabaseEditorCoordinator
    let chooseIcon: () -> Void
    let chooseParent: () -> Void
    let complete: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                Form {
                    TextField("Name:", text: $form.name)
                        .accessibilityIdentifier("group-edit.name-field")
                    LabeledContent("Icon:") {
                        HStack {
                            StandardIconView(iconID: form.iconID).font(.title).frame(width: 28, height: 28)
                            Button("Choose…", action: chooseIcon).accessibilityIdentifier("group-edit.icon-button")
                                .accessibilityValue(String(form.iconID))
                            Spacer()
                        }
                    }
                    LabeledContent("Location:") {
                        HStack {
                            Text(form.parentPath(in: database)).accessibilityIdentifier("group-edit.location")
                            Spacer()
                            Button("Move to Group…", action: chooseParent).accessibilityIdentifier("group-edit.move")
                        }
                    }
                    LabeledContent("Tags:") {
                        VStack(alignment: .leading, spacing: 6) {
                            FlowLayout(spacing: 6) {
                                ForEach(Array(form.tags.enumerated()), id: \.offset) { index, tag in
                                    Button { form.removeTag(tag) } label: { TagCapsule(tag: tag, trailingSystemImage: "xmark") }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(Text("Remove tag \(tag)"))
                                        .accessibilityIdentifier("group-edit.tag.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: index))")
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("group-edit.tags")
                            TextField("Add a tag", text: $form.pendingTagText).onSubmit { form.commitPendingTag() }
                                .accessibilityIdentifier("group-edit.tags-field")
                            FlowLayout(spacing: 6) {
                                ForEach(Array(form.tagSuggestions.enumerated()), id: \.offset) { index, tag in
                                    Button { form.appendTagSuggestion(tag) } label: { TagCapsule(tag: tag, systemImage: "plus") }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(Text("Add tag \(tag)"))
                                        .accessibilityIdentifier("group-edit.tag-suggestion.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: index))")
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("group-edit.tag-suggestions")
                            Text("Entries in this group and its subgroups inherit these tags.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Notes:") {
                        TextEditor(text: $form.notes).frame(height: 100).border(.separator)
                            .accessibilityIdentifier("group-edit.notes-field")
                    }
                    LabeledContent("Search & AutoFill:") {
                        VStack(alignment: .leading) {
                            Toggle("Hide from Search & AutoFill", isOn: $form.isHiddenFromAutoFill)
                                .accessibilityIdentifier("group-edit.autofill-toggle")
                            if form.isExclusionInherited {
                                Text("A parent group is hidden from Search & AutoFill. Turn this off to show this group anyway.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.formStyle(.columns).textFieldStyle(.roundedBorder).padding(.vertical, 4)
            }
            if let error = coordinator.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { coordinator.discard { _ in complete() } }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("group-edit.cancel")
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(!coordinator.canSave).accessibilityIdentifier("group-edit.save")
            }
        }
        .disabled(coordinator.isSavingInProgress)
        .onChange(of: form.isDirty) { coordinator.synchronizeUnsavedChanges() }
        .onChange(of: coordinator.conflictHasSettled) { coordinator.completeAfterConflictIfSettled { _ in complete() } }

    }

    private func save() {
        Task { await coordinator.save() { _ in complete() } }
    }
}

struct MacNewGroupView: View {
    @Binding var name: String
    let parentName: String
    @Binding var error: String?
    let cancel: () -> Void
    let create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                LabeledContent("Name:") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Group Name", text: $name).accessibilityIdentifier("group-create.name-field")
                        Text("Created in \(parentName).").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.columns).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red) }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("group-create.cancel")
                Button("Create", action: create).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("group-create.confirm")
            }
        }
    }
}
