#if os(macOS)
import AppKit
import OneTimeCodes
import SwiftUI
import UniformTypeIdentifiers

/// The inline entry editor (EditEntry, NewEntry, CodeSetup and UnsavedChanges boards): a header
/// with the title field, Cancel and Save / Create, then cards in the detail's grid. The form, its
/// coordinator and its reveals live on `MacEntryEditorSession`, so a redraw keeps unsaved work.
struct MacEntryEditorView: View {
    let session: MacEntryEditorSession
    @Bindable var form: EntryEditViewModel
    @Bindable var viewModel: DatabaseViewModel

    @State private var width: CGFloat = 600
    @State private var showDiscardConfirmation = false
    @State private var showGenerator = false
    @State private var showTOTPSetup = false
    @State private var showRemoveTOTPConfirmation = false
    @State private var showAttachmentImporter = false
    @State private var showCustomFieldOrder = false
    @State private var isTOTPAdvancedExpanded = false
    @State private var attachmentErrorMessage: String?
    /// Committed to the form only when it parses to a positive period; focus loss snaps it back.
    @State private var totpPeriodText: String
    @FocusState private var isTitleFocused: Bool
    @FocusState private var isTOTPPeriodFocused: Bool

    init(session: MacEntryEditorSession, viewModel: DatabaseViewModel) {
        self.session = session
        form = session.form
        self.viewModel = viewModel
        _totpPeriodText = State(initialValue: String(session.form.totpPeriod))
    }

    private var metrics: MacDetailMetrics { .forWidth(width) }
    private var coordinator: DatabaseEditorCoordinator { session.coordinator }
    private var pendingLockRequest: DatabaseViewModel.PendingLockRequest? { coordinator.pendingLockRequest }

    var body: some View {
        ScrollView(.vertical) {
            content
                .padding(metrics.contentInsets)
                .frame(maxWidth: MacDetailMetrics.maximumContentWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .environment(\.macDetailMetrics, metrics)
        .background(MacDetailPalette.column)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .disabled(coordinator.isSavingInProgress)
        .overlay { savingOverlay }
        .modifier(MacEntryEditorLifecycle(
            session: session, form: form, viewModel: viewModel,
            totpPeriodText: $totpPeriodText, isTOTPPeriodFocused: isTOTPPeriodFocused,
            dismissPresentations: dismissPresentations
        ))
        .modifier(MacEntryEditorAlerts(
            session: session, form: form,
            showDiscardConfirmation: $showDiscardConfirmation,
            showRemoveTOTPConfirmation: $showRemoveTOTPConfirmation,
            attachmentErrorMessage: $attachmentErrorMessage,
            onRemoveTOTP: removeTOTP
        ))
        .sheet(isPresented: $showTOTPSetup) {
            MacTOTPSetupSheet { form.applySetupInput($0) }
        }
        .modifier(EntryCustomFieldOrderSheet(isPresented: $showCustomFieldOrder, form: form))
        .fileImporter(isPresented: $showAttachmentImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true, onCompletion: importAttachments)
        .onAppear {
            guard session.hasFocusedTitle == false else { return }
            session.hasFocusedTitle = true
            // On appear the field is not in the window yet, so a focus request then is dropped.
            Task { @MainActor in isTitleFocused = true }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: metrics.sectionGap) {
            header
            if let reason = session.cannotSaveReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.State.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("entry-edit.unavailable")
            }
            MacDetailCard {
                usernameRow
                passwordRow
                websiteRows
                verificationCodeRows
            }
            MacDetailCard {
                notesRow
                tagsRow
                groupRow
                expiryRow
            }
            if form.customFields.isEmpty == false {
                MacDetailCard {
                    ForEach(Array(form.customFields.enumerated()), id: \.element.id) { index, field in
                        customFieldRow(field, index: index)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Custom Fields"))
            }
            if form.attachments.isEmpty == false {
                MacDetailCard {
                    ForEach(Array(form.attachments.enumerated()), id: \.element.id) { index, attachment in
                        attachmentRow(attachment, index: index)
                    }
                }
            }
            addButtons
            if form.unknownXMLNodeCount > 0 {
                Text("Unknown KeePass XML will be preserved when you save this entry.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, metrics.footerInset)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: metrics.headerGap) {
            headerIcon
            VStack(alignment: .leading, spacing: 5) {
                TextField("Title", text: $form.title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                    .focused($isTitleFocused)
                    .accessibilityIdentifier("entry-edit.title-field")
                Text(subline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("Cancel", action: cancelTapped)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(coordinator.isSavingInProgress)
                .accessibilityIdentifier("entry-edit.cancel")
            // ⌘S comes from File ▸ Save, which saves this editor; Return stays in the fields.
            Button { session.save() } label: {
                HStack(spacing: 6) {
                    Text(session.isEditingExistingEntry ? String(localized: "Save") : String(localized: "Create"))
                        .fontWeight(.semibold)
                    Text(verbatim: "⌘S")
                        .font(.caption.weight(.medium))
                        .opacity(0.72)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(session.canSave == false)
            .accessibilityIdentifier("entry-edit.save")
        }
    }

    @ViewBuilder
    private var headerIcon: some View {
        if case .edit(let entryID) = form.mode, let entry = viewModel.entry(withID: entryID) {
            FaviconView(url: entry.url, iconID: entry.iconID, size: MacDetailMetrics.headerIconSize,
                        customIconData: viewModel.customIconData(for: entry))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 18)
                .fill(.quaternary)
                .frame(width: MacDetailMetrics.headerIconSize, height: MacDetailMetrics.headerIconSize)
                .overlay {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
    }

    private var groupID: UUID? {
        switch form.mode {
        case .edit(let entryID): viewModel.parentGroupID(forEntryID: entryID)
        case .create(let groupID): groupID
        }
    }

    private var groupPathComponents: [String] {
        guard let groupID else { return [] }
        return MacEntryEditorSession.groupPath(of: groupID, in: viewModel.groupDestinationOptions(currentGroupID: groupID))
    }

    private var subline: String {
        let state = session.isEditingExistingEntry ? String(localized: "Editing") : String(localized: "New Entry")
        let path = groupPathComponents.joined(separator: " › ")
        return path.isEmpty ? state : "\(path) · \(state)"
    }

    // MARK: - Main card

    private var usernameRow: some View {
        MacDetailRow(label: String(localized: "Username"), isFirst: true) {
            TextField("Username", text: $form.username)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .autocorrectionDisabled()
                .accessibilityIdentifier("entry-edit.username-field")
        } trailing: {
            EmptyView()
        }
    }

    private var passwordRow: some View {
        MacDetailRow(label: String(localized: "Password")) {
            HStack(spacing: 12) {
                MacEditorSecretField(
                    title: String(localized: "Password"), text: $form.password, isVisible: session.isPasswordVisible,
                    identifier: "entry-edit.password-field"
                )
                if let estimate = PasswordStrengthEstimator.estimate(form.password) {
                    MacStrengthMeter(estimate: estimate, showsWord: false)
                }
            }
        } trailing: {
            MacDetailIconButton(
                systemImage: session.isPasswordVisible ? "eye.slash" : "eye",
                label: revealLabel(String(localized: "Password"), isVisible: session.isPasswordVisible)
            ) { session.togglePasswordVisibility() }
            .disabled(session.isAuthenticating)
            .accessibilityIdentifier("entry-edit.password-visibility-button")
            Button("Generate") { showGenerator = true }
                .frame(width: 92)
                .accessibilityIdentifier("entry-edit.password-generator-button")
                .popover(isPresented: $showGenerator, arrowEdge: .bottom) {
                    MacPasswordGeneratorPopover { form.password = $0 }
                }
        }
        .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder
    private var websiteRows: some View {
        MacDetailRow(label: String(localized: "Website"), alignsTop: true) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Website", text: $form.url)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("entry-edit.url-field")
                if form.additionalURLs.isEmpty { addURLLink }
            }
        } trailing: {
            EmptyView()
        }
        ForEach(Array(form.additionalURLs.enumerated()), id: \.element.id) { index, additionalURL in
            additionalURLRow(additionalURL, index: index, isLast: index == form.additionalURLs.count - 1)
        }
    }

    private func additionalURLRow(_ additionalURL: EntryEditViewModel.AdditionalURL, index: Int, isLast: Bool) -> some View {
        let title = String(localized: "Website \(index + 2)")
        let removeLabel = String(localized: "Remove Website \(index + 2)")
        let binding = Binding(
            get: { form.additionalURLs.first { $0.id == additionalURL.id }?.value ?? "" },
            set: { value in
                guard let position = form.additionalURLs.firstIndex(where: { $0.id == additionalURL.id }) else { return }
                form.additionalURLs[position].value = value
            }
        )
        return MacDetailRow(label: title, alignsTop: isLast) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(title, text: binding)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("entry-edit.additional-url.field.\(index)")
                if isLast { addURLLink }
            }
        } trailing: {
            MacDetailIconButton(systemImage: "minus.circle", label: removeLabel, tone: Theme.State.danger) {
                form.removeAdditionalURL(id: additionalURL.id)
            }
            .accessibilityIdentifier("entry-edit.additional-url.remove.\(index)")
        }
    }

    private var addURLLink: some View {
        Button { form.addAdditionalURL() } label: {
            Label("Add Another URL", systemImage: "plus")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .accessibilityIdentifier("entry-edit.additional-url.add")
    }

    // MARK: - Verification code

    @ViewBuilder
    private var verificationCodeRows: some View {
        MacDetailRow(label: String(localized: "Verification Code")) {
            if form.hasTOTPSecret {
                HStack(spacing: 10) {
                    if let preview = form.totpPreview {
                        MacEditorCodePreview(preview: preview)
                    } else if let message = form.unsupportedTOTPDigitsMessage {
                        Text(message)
                            .foregroundStyle(Theme.State.danger)
                            .accessibilityIdentifier("entry-edit.totp.digits-error")
                    } else {
                        Text("Enter a valid secret key to see the current code.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("entry-edit.totp.preview-unavailable")
                    }
                    Button("Advanced Options") { isTOTPAdvancedExpanded.toggle() }
                        .buttonStyle(.link)
                        .font(.callout)
                        .accessibilityAddTraits(isTOTPAdvancedExpanded ? .isSelected : [])
                        .accessibilityIdentifier("entry-edit.totp.advanced")
                }
            } else {
                HStack(spacing: 10) {
                    Button("Set Up…") { showTOTPSetup = true }
                        .accessibilityIdentifier("entry-edit.totp.enter-link")
                    Text("Paste a setup link or setup key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } trailing: {
            if form.hasTOTPSecret {
                MacDetailIconButton(systemImage: "minus.circle", label: String(localized: "Remove Verification Code"),
                                    tone: Theme.State.danger) {
                    showRemoveTOTPConfirmation = true
                }
                .accessibilityIdentifier("entry-edit.totp.remove")
            }
        }
        if form.hasTOTPSecret, isTOTPAdvancedExpanded {
            totpAdvancedRows
                .background(Color.primary.opacity(0.02))
        }
    }

    @ViewBuilder
    private var totpAdvancedRows: some View {
        MacDetailRow(label: String(localized: "Secret Key")) {
            MacEditorSecretField(
                title: String(localized: "Secret Key"), text: $form.totpSecret, isVisible: session.isTOTPSecretVisible,
                identifier: "entry-edit.totp.secret-field"
            )
        } trailing: {
            MacDetailIconButton(
                systemImage: session.isTOTPSecretVisible ? "eye.slash" : "eye",
                label: revealLabel(String(localized: "Secret Key"), isVisible: session.isTOTPSecretVisible)
            ) { session.toggleTOTPSecretVisibility() }
            .disabled(session.isAuthenticating)
            .accessibilityIdentifier("entry-edit.totp.secret-visibility-button")
        }
        MacDetailRow(label: String(localized: "Period (Seconds)")) {
            TextField("Period (Seconds)", text: $totpPeriodText)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .focused($isTOTPPeriodFocused)
                .onSubmit(snapBackInvalidTOTPPeriodText)
                .accessibilityIdentifier("entry-edit.totp.period-field")
        } trailing: {
            EmptyView()
        }
        MacDetailRow(label: String(localized: "Digits")) {
            // The entry's storage format decides what is offered, plus the current value, so the pop-up never shows blank.
            Picker("Digits", selection: $form.totpDigits) {
                ForEach(Array(Set(form.supportedTOTPDigits + [form.totpDigits])).sorted(), id: \.self) { digits in
                    Text(verbatim: String(digits)).tag(digits)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("entry-edit.totp.digits-picker")
        } trailing: {
            EmptyView()
        }
        MacDetailRow(label: String(localized: "Algorithm")) {
            Picker("Algorithm", selection: $form.totpAlgorithm) {
                Text(verbatim: "SHA-1").tag(TOTPAlgorithm.sha1)
                Text(verbatim: "SHA-256").tag(TOTPAlgorithm.sha256)
                Text(verbatim: "SHA-512").tag(TOTPAlgorithm.sha512)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("entry-edit.totp.algorithm-picker")
        } trailing: {
            EmptyView()
        }
    }

    // MARK: - Second card

    private var notesRow: some View {
        MacDetailRow(label: String(localized: "Notes"), isFirst: true, minHeight: 80, alignsTop: true) {
            TextEditor(text: $form.notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 62)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityLabel(Text("Notes"))
                .accessibilityIdentifier("entry-edit.notes-field")
        } trailing: {
            EmptyView()
        }
    }

    private var tagsRow: some View {
        MacDetailRow(label: String(localized: "Tags"), alignsTop: form.tagSuggestions.isEmpty == false) {
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 4) {
                    ForEach(Array(form.tags.enumerated()), id: \.offset) { index, tag in
                        Button { form.removeTag(tag) } label: {
                            TagCapsule(tag: tag, trailingSystemImage: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Remove tag \(tag)"))
                        .accessibilityIdentifier(
                            "entry-edit.tag.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: index))"
                        )
                    }
                    // Single-line: Return commits the tag rather than inserting a newline.
                    TextField("Add a tag", text: $form.pendingTagText)
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .autocorrectionDisabled()
                        .frame(minWidth: 120)
                        .onSubmit { form.commitPendingTag() }
                        .accessibilityIdentifier("entry-edit.tags-field")
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("entry-edit.tags")
                tagSuggestions
            }
        } trailing: {
            EmptyView()
        }
    }

    @ViewBuilder
    private var tagSuggestions: some View {
        let suggestions = form.tagSuggestions
        if suggestions.isEmpty == false {
            FlowLayout(spacing: 6) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, tag in
                    Button { form.appendTagSuggestion(tag) } label: {
                        TagCapsule(tag: tag, systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Add tag \(tag)"))
                    .accessibilityIdentifier(
                        "entry-edit.tag-suggestion.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: index))"
                    )
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("entry-edit.tag-suggestions")
        }
    }

    /// A new entry picks its group here; an edited entry moves through Move to Group….
    private var groupRow: some View {
        MacDetailRow(label: String(localized: "Group")) {
            if let destinationID = form.createDestinationGroupID {
                let options = viewModel.groupDestinationOptions(currentGroupID: destinationID)
                Picker("Group", selection: Binding(
                    get: { destinationID },
                    set: { groupID in
                        form.setCreateDestination(to: groupID, inheritedTags: viewModel.inheritedTags(forGroupID: groupID))
                    }
                )) {
                    ForEach(options) { option in
                        Text(MacEntryEditorSession.groupLabel(of: option.id, in: options))
                            .tag(option.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("entry-edit.group")
            } else {
                Text(groupID.map { MacEntryEditorSession.groupLabel(of: $0, in: viewModel.groupDestinationOptions(currentGroupID: $0)) } ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("entry-edit.group")
            }
        } trailing: {
            EmptyView()
        }
    }

    private var expiryRow: some View {
        MacDetailRow(label: String(localized: "Expires")) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Toggle("Expires", isOn: $form.expires)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityIdentifier("entry-edit.expiry.toggle")
                    if form.expires {
                        DatePicker("Expiry Date", selection: $form.expiryDate, displayedComponents: [.date])
                            .datePickerStyle(.stepperField)
                            .labelsHidden()
                            .accessibilityIdentifier("entry-edit.expiry.date-picker")
                        Text(MacEntryFormatting.expiryCaption(form.expiryDate))
                            .font(.caption)
                            .foregroundStyle(form.isExpiryDateInPast ? AnyShapeStyle(Theme.State.danger) : AnyShapeStyle(.secondary))
                        expiryPresets
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                }
                if form.expires, form.isExpiryDateInPast {
                    Text("This date has passed, so the entry will show as expired.")
                        .font(.caption)
                        .foregroundStyle(Theme.State.danger)
                        .accessibilityIdentifier("entry-edit.expiry.past-warning")
                }
            }
        } trailing: {
            EmptyView()
        }
    }

    private var expiryPresets: some View {
        Menu("Presets") {
            Button("In 1 Month") { form.applyExpiryPreset(months: 1) }
                .accessibilityIdentifier("entry-edit.expiry.preset.1")
            Button("In 3 Months") { form.applyExpiryPreset(months: 3) }
                .accessibilityIdentifier("entry-edit.expiry.preset.3")
            Button("In 6 Months") { form.applyExpiryPreset(months: 6) }
                .accessibilityIdentifier("entry-edit.expiry.preset.6")
            Button("In 1 Year") { form.applyExpiryPreset(months: 12) }
                .accessibilityIdentifier("entry-edit.expiry.preset.12")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier("entry-edit.expiry.presets")
    }

    // MARK: - Custom fields

    private func customFieldRow(_ field: EntryEditViewModel.CustomField, index: Int) -> some View {
        MacEditorCustomFieldRow(
            session: session, field: field, index: index,
            isLast: index == form.customFields.count - 1
        )
    }

    // MARK: - Attachments

    private func attachmentRow(_ attachment: EntryEditViewModel.Attachment, index: Int) -> some View {
        let label = index == 0 ? (form.attachments.count == 1 ? String(localized: "Attachment") : String(localized: "Attachments")) : ""
        return MacDetailRow(label: label, isFirst: index == 0) {
            HStack(spacing: 8) {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: attachment.name.isEmpty ? "?" : attachment.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                attachmentSize(attachment)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        } trailing: {
            MacDetailIconButton(systemImage: "minus.circle", label: String(localized: "Remove attachment \(attachment.name)"),
                                tone: Theme.State.danger) {
                form.removeAttachment(id: attachment.id)
            }
            .accessibilityIdentifier("entry-edit.attachment.remove.\(index)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entry-edit.attachment.row.\(index)")
    }

    private func attachmentSize(_ attachment: EntryEditViewModel.Attachment) -> Text {
        let byteCount: Int? = switch attachment.source {
        case .existing(let stored): viewModel.attachmentByteCount(for: stored)
        case .new(let data): data.count
        }
        guard let byteCount else { return Text("Unavailable") }
        return Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
    }

    private var addButtons: some View {
        HStack(spacing: 8) {
            Button { form.addCustomField() } label: {
                Label("Add Field", systemImage: "plus")
            }
            .accessibilityIdentifier("entry-edit.custom-field.add")
            Button { showAttachmentImporter = true } label: {
                Label("Add Attachment…", systemImage: "plus")
            }
            .disabled(session.attachmentLoads.isLoading)
            .accessibilityIdentifier("entry-edit.attachment.add")
            if session.attachmentLoads.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("entry-edit.attachment.importing")
            }
            if form.customFields.count > 1 {
                Button("Reorder Fields…") { showCustomFieldOrder = true }
                    .buttonStyle(.link)
                    .font(.callout)
                    .accessibilityIdentifier("entry-edit.custom-field.reorder")
            }
        }
        .padding(.leading, metrics.footerInset)
        .padding(.top, -4)
    }

    // MARK: - Saving

    @ViewBuilder
    private var savingOverlay: some View {
        if coordinator.isSubmitting && viewModel.isSaving == false {
            ZStack {
                Color.black.opacity(0.14)
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Saving changes...")
                        .font(.headline)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Saving changes")
            .accessibilityIdentifier("entry-edit.saving-overlay")
        }
    }

    // MARK: - Actions

    private func cancelTapped() {
        if form.isDirty {
            showDiscardConfirmation = true
        } else {
            session.discard()
        }
    }

    private func removeTOTP() {
        form.removeTOTP()
        isTOTPAdvancedExpanded = false
        totpPeriodText = String(form.totpPeriod)
    }

    private func snapBackInvalidTOTPPeriodText() {
        if Int(totpPeriodText).map({ $0 > 0 }) != true {
            totpPeriodText = String(form.totpPeriod)
        }
    }

    private func importAttachments(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            session.importAttachments(urls) { attachmentErrorMessage = $0.localizedDescription }
        case .failure(let error):
            attachmentErrorMessage = error.localizedDescription
        }
    }

    /// A lock prompt must not sit under anything presented above the editor.
    private func dismissPresentations() {
        showGenerator = false
        showTOTPSetup = false
        showRemoveTOTPConfirmation = false
        showDiscardConfirmation = false
        showAttachmentImporter = false
        showCustomFieldOrder = false
        attachmentErrorMessage = nil
    }
}

// MARK: - Lifecycle and alerts

/// Keeps the coordinator's registration and the reveal gate in step with the form.
private struct MacEntryEditorLifecycle: ViewModifier {
    let session: MacEntryEditorSession
    let form: EntryEditViewModel
    let viewModel: DatabaseViewModel
    @Binding var totpPeriodText: String
    let isTOTPPeriodFocused: Bool
    let dismissPresentations: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: form.isDirty) { session.coordinator.synchronizeUnsavedChanges() }
            .onChange(of: session.coordinator.conflictHasSettled) { session.completeAfterConflictIfSettled() }
            .onChange(of: form.password) { session.secretsChanged() }
            .onChange(of: form.totpSecret) { session.secretsChanged() }
            .onChange(of: form.customFields) { session.secretsChanged() }
            .onChange(of: session.coordinator.pendingLockRequest != nil) { _, isPending in
                if isPending { dismissPresentations() }
            }
            .onChange(of: totpPeriodText) { _, newValue in
                if let period = Int(newValue), period > 0 { form.totpPeriod = period }
            }
            .onChange(of: form.totpPeriod) { _, newValue in
                if Int(totpPeriodText) != newValue { totpPeriodText = String(newValue) }
            }
            .onChange(of: isTOTPPeriodFocused) { _, isFocused in
                if isFocused == false, Int(totpPeriodText).map({ $0 > 0 }) != true {
                    totpPeriodText = String(form.totpPeriod)
                }
            }
            .onDisappear { session.secretsChanged() }
    }
}

private struct MacEntryEditorAlerts: ViewModifier {
    let session: MacEntryEditorSession
    let form: EntryEditViewModel
    @Binding var showDiscardConfirmation: Bool
    @Binding var showRemoveTOTPConfirmation: Bool
    @Binding var attachmentErrorMessage: String?
    let onRemoveTOTP: () -> Void

    private var pendingLockRequest: DatabaseViewModel.PendingLockRequest? { session.coordinator.pendingLockRequest }

    func body(content: Content) -> some View {
        content
            .alert("Save your changes before locking?", isPresented: Binding(
                get: { pendingLockRequest != nil },
                set: { _ in }
            )) {
                Button("Save and Lock") {
                    guard let request = pendingLockRequest else { return }
                    session.save(resuming: request)
                }
                .disabled(session.canSaveAndLock == false)
                Button("Discard and Lock", role: .destructive) {
                    guard let request = pendingLockRequest else { return }
                    session.discard(resuming: request)
                }
                Button("Keep Editing", role: .cancel) {
                    Task { await session.coordinator.continueEditingAfterLockRequest() }
                }
            } message: {
                Text(verbatim: form.saveBeforeLockMessage)
            }
            .alert("Discard changes?", isPresented: $showDiscardConfirmation) {
                Button("Discard Changes", role: .destructive) { session.discard() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your entry changes haven't been saved to this database draft yet.")
            }
            .alert("Remove Verification Code", isPresented: $showRemoveTOTPConfirmation) {
                Button("Remove", role: .destructive, action: onRemoveTOTP)
                    .accessibilityIdentifier("entry-edit.totp.remove-confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The verification code will no longer be generated for this entry.")
            }
            .alert("Couldn’t Update Entry", isPresented: Binding(
                get: { session.coordinator.errorMessage != nil },
                set: { if $0 == false { session.coordinator.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(session.coordinator.errorMessage ?? "")
            }
            .alert("Couldn’t Add Attachment", isPresented: Binding(
                get: { attachmentErrorMessage != nil },
                set: { if $0 == false { attachmentErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(attachmentErrorMessage ?? "")
            }
    }
}

// MARK: - Rows

/// "Show Password" / "Hide Password", the shared editors' reveal labels.
private func revealLabel(_ title: String, isVisible: Bool) -> String {
    isVisible ? String(localized: "Hide \(title)") : String(localized: "Show \(title)")
}

/// A secret in the editor: dots until revealed, then plain monospaced text.
private struct MacEditorSecretField: View {
    let title: String
    @Binding var text: String
    let isVisible: Bool
    let identifier: String

    var body: some View {
        Group {
            if isVisible {
                TextField(title, text: $text)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
            } else {
                SecureField(title, text: $text)
            }
        }
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .accessibilityIdentifier(identifier)
    }
}

/// The form's live code: "482 913" with its ring.
private struct MacEditorCodePreview: View {
    let preview: EntryEditViewModel.TOTPPreview
    /// Ticks on whole seconds, so the code changes on its period boundary.
    private let tickStart = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    var body: some View {
        TimelineView(.periodic(from: tickStart, by: 1)) { context in
            let seconds = preview.secondsRemaining(at: context.date)
            HStack(spacing: 8) {
                Text(TOTPViewModel.grouped(preview.code(at: context.date)))
                    .font(.title3.monospaced().weight(.semibold))
                    .foregroundStyle(.tint)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("entry-edit.totp.preview-code")
                MacCountdownRing(seconds: seconds, progress: Double(seconds) / Double(preview.period))
                    .frame(width: 20, height: 20)
            }
        }
    }
}

/// Field name in the label column, the value, then Protect Field and Remove Field; move up and
/// down are VoiceOver actions, Reorder Fields… is the pointer's way.
private struct MacEditorCustomFieldRow: View {
    let session: MacEntryEditorSession
    let field: EntryEditViewModel.CustomField
    let index: Int
    let isLast: Bool
    @Environment(\.macDetailMetrics) private var metrics

    private var form: EntryEditViewModel { session.form }
    private var name: String { field.key.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isRevealed: Bool { session.revealedCustomFieldIDs.contains(field.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if index > 0 { Divider() }
            HStack(spacing: metrics.columnGap) {
                TextField("Field Name", text: binding(\.key))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .font(.callout)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .frame(width: metrics.labelWidth)
                    .accessibilityLabel(Text("Field Name"))
                    .accessibilityIdentifier("entry-edit.custom-field.name-field.\(index)")
                valueField
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 2) {
                    if field.isProtected {
                        MacDetailIconButton(
                            systemImage: isRevealed ? "eye.slash" : "eye",
                            label: revealLabel(name.isEmpty ? String(localized: "Field Value") : name, isVisible: isRevealed)
                        ) { session.toggleCustomFieldVisibility(field.id) }
                        .disabled(session.isAuthenticating)
                        .accessibilityIdentifier("entry-edit.custom-field.value-visibility-button.\(index)")
                    }
                    MacDetailIconButton(systemImage: field.isProtected ? "lock.fill" : "lock.open",
                                        label: protectLabel, isOn: field.isProtected) {
                        session.setCustomFieldProtection(field.id, isProtected: field.isProtected == false)
                    }
                    .disabled(session.isAuthenticating)
                    .accessibilityAddTraits(field.isProtected ? .isSelected : [])
                    .accessibilityIdentifier("entry-edit.custom-field.protection.\(index)")
                    MacDetailIconButton(systemImage: "minus.circle", label: removeLabel, tone: Theme.State.danger) {
                        session.removeCustomField(field.id)
                    }
                    .accessibilityIdentifier("entry-edit.custom-field.remove.\(index)")
                }
            }
            .padding(.horizontal, metrics.rowPadding)
            .padding(.vertical, 4)
            .frame(minHeight: MacDetailMetrics.rowHeight)
            if let message = form.customFieldValidationMessage(for: field) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.State.danger)
                    .padding(.leading, metrics.footerInset)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("entry-edit.custom-field.error.\(index)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name.isEmpty ? Text("Field Value") : Text(verbatim: name))
        .accessibilityIdentifier(form.customFieldAccessibilityIdentifier(for: field, fallbackIndex: index))
        .accessibilityAction(named: Text("Move Up")) { form.moveCustomField(id: field.id, offset: -1) }
        .accessibilityAction(named: Text("Move Down")) { form.moveCustomField(id: field.id, offset: 1) }
    }

    @ViewBuilder
    private var valueField: some View {
        let label = name.isEmpty ? String(localized: "Field Value") : name
        Group {
            if field.isProtected && isRevealed == false {
                SecureField(label, text: binding(\.value))
            } else {
                TextField(label, text: binding(\.value))
                    .font(field.isProtected ? .body.monospaced() : .body)
                    .autocorrectionDisabled()
            }
        }
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier("entry-edit.custom-field.value-field.\(index)")
    }

    private var protectLabel: String {
        name.isEmpty ? String(localized: "Protect Field") : String(localized: "Protect field \(name)")
    }

    private var removeLabel: String {
        name.isEmpty ? String(localized: "Remove Field") : String(localized: "Remove field \(name)")
    }

    private func binding(_ keyPath: WritableKeyPath<EntryEditViewModel.CustomField, String>) -> Binding<String> {
        let id = field.id
        let form = form
        return Binding(
            get: { form.customFields.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { value in
                guard let position = form.customFields.firstIndex(where: { $0.id == id }) else { return }
                form.customFields[position][keyPath: keyPath] = value
            }
        )
    }
}
#endif
