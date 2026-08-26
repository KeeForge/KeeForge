import SwiftUI

struct EntryEditView: View {
    typealias Completion = EntryEditCompletion

    @State private var formViewModel: EntryEditViewModel
    @Bindable var databaseViewModel: DatabaseViewModel
    let onComplete: (Completion) -> Void

    @State private var showDiscardConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showPasswordGenerator = false
    @State private var isPasswordVisible: Bool
    @State private var isAuthenticatingReveal = false
    @State private var editingErrorMessage: String?
    @State private var isSubmitting = false
    @State private var completionGate = EntryEditCompletionGate()

    @State private var isTOTPSecretVisible: Bool
    @State private var isManualTOTPEntryActive = false
    @State private var showTOTPScanner = false
    @State private var showTOTPSetupLink = false
    @State private var showGroupPicker = false
    @State private var showRemoveTOTPConfirmation = false
    /// String mirror for the numeric period field; committed to the view
    /// model only when it parses to a positive integer. Focus loss and submit
    /// snap unparsable text back to the view model's value, so the field
    /// never keeps showing a period that Save would not write.
    @State private var totpPeriodText: String
    @FocusState private var isTOTPPeriodFieldFocused: Bool

    private var isSavingInProgress: Bool {
        isSubmitting || databaseViewModel.isSaving
    }

    private var isEntryInRecycleBin: Bool {
        guard case .edit(let entryID) = formViewModel.mode else { return false }
        return databaseViewModel.isEntryInRecycleBin(entryID: entryID)
    }

    init(
        formViewModel: EntryEditViewModel,
        databaseViewModel: DatabaseViewModel,
        onComplete: @escaping (Completion) -> Void = { _ in }
    ) {
        _formViewModel = State(initialValue: formViewModel)
        _isPasswordVisible = State(initialValue: formViewModel.isPasswordInitiallyVisible)
        _isTOTPSecretVisible = State(initialValue: formViewModel.isPasswordInitiallyVisible)
        _totpPeriodText = State(initialValue: String(formViewModel.totpPeriod))
        self.databaseViewModel = databaseViewModel
        self.onComplete = onComplete
    }

    var body: some View {
        Form {
            Section("Basics") {
                basicFieldRow("Title") {
                    TextField("Title", text: $formViewModel.title)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("entry-edit.title-field")
                }

                basicFieldRow("Username") {
                    TextField("Username", text: $formViewModel.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("entry-edit.username-field")
                }

                basicFieldRow("Password") {
                    PasswordInputRow(
                        title: String(localized: "Password"),
                        text: $formViewModel.password,
                        isVisible: $isPasswordVisible,
                        fieldAccessibilityIdentifier: "entry-edit.password-field",
                        visibilityAccessibilityIdentifier: "entry-edit.password-visibility-button",
                        onVisibilityToggle: togglePasswordVisibility
                    ) {
                        Button {
                            showPasswordGenerator = true
                        } label: {
                            Image(systemName: "dice.fill")
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Generate password")
                        .accessibilityIdentifier("entry-edit.password-generator-button")
                        .macHelp(String(localized: "Generate password"))
                    }

                    PasswordStrengthIndicator(password: formViewModel.password)
                }

                basicFieldRow("URL") {
                    TextField("URL", text: $formViewModel.url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .accessibilityIdentifier("entry-edit.url-field")
                }

                basicFieldRow("Tags") {
                    appliedTagStrip

                    // Single-line on purpose: Return has to submit the tag
                    // rather than insert a newline, which is the only visible
                    // hint that tags are committed one at a time.
                    TextField("Add a tag", text: $formViewModel.pendingTagText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { formViewModel.commitPendingTag() }
                        .accessibilityIdentifier("entry-edit.tags-field")

                    tagSuggestionStrip
                }
            }

            if formViewModel.createDestinationGroupID != nil {
                Section("Group") {
                    destinationGroupRow
                }
            }

            Section("One-Time Password") {
                if isTOTPConfigurationVisible {
                    totpConfigurationRows
                } else {
                    totpEntryPathRows
                }
            }

            Section("Notes") {
                TextEditor(text: $formViewModel.notes)
                    .frame(minHeight: 180)
                    .accessibilityIdentifier("entry-edit.notes-field")
            }

            if formViewModel.passkeyCredential != nil || formViewModel.unknownXMLNodeCount > 0 {
                Section("Preserved Read-Only Data") {
                    if let passkey = formViewModel.passkeyCredential {
                        LabeledContent("Passkey Relying Party", value: passkey.relyingParty)
                        LabeledContent("Passkey Username", value: passkey.username)
                    }

                    if formViewModel.unknownXMLNodeCount > 0 {
                        Text("Unknown KeePass XML will be preserved when you save this entry.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if case .edit = formViewModel.mode {
                Section {
                    Button("Delete Entry", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("entry-edit.delete")
                    // Attached to the button (not the Form) so iOS anchors the
                    // dialog to its source control instead of an arbitrary
                    // popover in the middle of the screen.
                    .confirmationDialog(
                        "Delete Entry",
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        if !isEntryInRecycleBin {
                            Button("Move to Recycle Bin", role: .destructive) {
                                deleteTapped(sendToRecycleBin: true)
                            }
                        }
                        Button("Delete Permanently", role: .destructive) {
                            deleteTapped(sendToRecycleBin: false)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(isEntryInRecycleBin
                            ? "This entry is already in the recycle bin. It will be permanently deleted."
                            : "Choose how to remove this entry.")
                    }
                }
            }
        }
        .macGroupedForm()
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .disabled(isSavingInProgress)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    cancelTapped()
                }
                .disabled(isSavingInProgress)
                .accessibilityIdentifier("entry-edit.cancel")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(confirmButtonTitle) {
                    saveTapped()
                }
                .disabled(formViewModel.canSave == false || isSavingInProgress)
                .accessibilityIdentifier("entry-edit.save")
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
                .accessibilityIdentifier("entry-edit.saving-overlay")
            }
        }
        .sheet(isPresented: $showPasswordGenerator) {
            PasswordGeneratorSheet { password in
                formViewModel.password = password
            }
            // Shorter than the default: the generator is a compact control
            // stack, not a form.
            .macSheetFrame(minHeight: 420)
        }
        #if os(iOS)
        .sheet(isPresented: $showTOTPScanner) {
            TOTPQRScannerSheet { uri in
                formViewModel.applyOTPAuthURI(uri)
            }
        }
        #endif
        .sheet(isPresented: $showTOTPSetupLink) {
            TOTPSetupLinkSheet { link in
                formViewModel.applySetupLink(link)
            }
        }
        .sheet(isPresented: $showGroupPicker) {
            // Options are resolved when the picker is built, not when the row
            // was tapped, so it reflects the tree as it is now.
            MoveToGroupPickerView(
                options: databaseViewModel.groupDestinationOptions(
                    currentGroupID: formViewModel.createDestinationGroupID
                ),
                navigationTitle: "Select Group"
            ) { groupID in
                formViewModel.setCreateDestination(
                    to: groupID,
                    inheritedTags: databaseViewModel.inheritedTags(forGroupID: groupID)
                )
            }
        }
        .onChange(of: totpPeriodText) { _, newValue in
            if let period = Int(newValue), period > 0 {
                formViewModel.totpPeriod = period
            }
        }
        .onChange(of: formViewModel.totpPeriod) { _, newValue in
            if Int(totpPeriodText) != newValue {
                totpPeriodText = String(newValue)
            }
        }
        .onChange(of: isTOTPPeriodFieldFocused) { _, isFocused in
            if isFocused == false {
                snapBackInvalidTOTPPeriodText()
            }
        }
        .onChange(of: conflictHasSettled) { _, settled in
            if let completion = completionGate.conflictSettled(settled) {
                onComplete(completion)
            }
        }
        .alert("Discard changes?", isPresented: $showDiscardConfirmation) {
            Button("Discard Changes", role: .destructive) {
                onComplete(.cancelled)
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your entry changes haven't been saved to this database draft yet.")
        }
        .alert(
            "Couldn’t Update Entry",
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

    private func togglePasswordVisibility() {
        toggleProtectedFieldVisibility($isPasswordVisible, reason: String(localized: "View password"))
    }

    private func toggleTOTPSecretVisibility() {
        toggleProtectedFieldVisibility(
            $isTOTPSecretVisible,
            reason: String(localized: "View verification code secret")
        )
    }

    /// Reveal is gated behind device-owner authentication in edit mode; a
    /// create-mode value was typed this session, so hiding and re-showing it
    /// stays ungated.
    private func toggleProtectedFieldVisibility(_ isVisible: Binding<Bool>, reason: String) {
        if isVisible.wrappedValue {
            HapticService.tap()
            isVisible.wrappedValue = false
            return
        }

        guard isAuthenticatingReveal == false else { return }
        guard formViewModel.requiresAuthenticationToRevealPassword,
              BiometricService.canAuthenticateDeviceOwner else {
            HapticService.tap()
            isVisible.wrappedValue = true
            return
        }

        isAuthenticatingReveal = true
        Task {
            do {
                _ = try await BiometricService.authenticateDeviceOwner(reason: reason)
                await MainActor.run {
                    HapticService.success()
                    isVisible.wrappedValue = true
                }
            } catch {
                // The stored secret stays concealed when authentication fails.
            }
            await MainActor.run {
                isAuthenticatingReveal = false
            }
        }
    }

    private var hasTOTPConfiguration: Bool {
        formViewModel.totpSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var isTOTPConfigurationVisible: Bool {
        hasTOTPConfiguration || isManualTOTPEntryActive
    }

    @ViewBuilder
    private var totpEntryPathRows: some View {
        #if os(iOS)
        Button {
            showTOTPScanner = true
        } label: {
            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
        }
        .accessibilityIdentifier("entry-edit.totp.scan-qr")
        #endif

        Button {
            showTOTPSetupLink = true
        } label: {
            Label("Enter Setup Link", systemImage: "link")
        }
        .accessibilityIdentifier("entry-edit.totp.enter-link")

        Button {
            isManualTOTPEntryActive = true
        } label: {
            Label("Enter Setup Key", systemImage: "keyboard")
        }
        .accessibilityIdentifier("entry-edit.totp.enter-key")
    }

    @ViewBuilder
    private var totpConfigurationRows: some View {
        basicFieldRow(String(localized: "Secret Key")) {
            PasswordInputRow(
                title: String(localized: "Secret Key"),
                text: $formViewModel.totpSecret,
                isVisible: $isTOTPSecretVisible,
                fieldAccessibilityIdentifier: "entry-edit.totp.secret-field",
                visibilityAccessibilityIdentifier: "entry-edit.totp.secret-visibility-button",
                onVisibilityToggle: toggleTOTPSecretVisibility,
                usesPasswordAutoFill: false
            )
        }

        basicFieldRow(String(localized: "Period (Seconds)")) {
            TextField(String(localized: "Period (Seconds)"), text: $totpPeriodText)
                .keyboardType(.numberPad)
                .focused($isTOTPPeriodFieldFocused)
                .onSubmit(snapBackInvalidTOTPPeriodText)
                .accessibilityIdentifier("entry-edit.totp.period-field")
        }

        // Only what the entry's storage format can hold is offered, plus the
        // current value — an enrolled URI may carry any digit count in 1...9,
        // and an untagged selection renders the picker blank.
        Picker("Digits", selection: $formViewModel.totpDigits) {
            ForEach(
                Array(Set(formViewModel.supportedTOTPDigits + [formViewModel.totpDigits])).sorted(),
                id: \.self
            ) { digits in
                Text(verbatim: String(digits)).tag(digits)
            }
        }
        .accessibilityIdentifier("entry-edit.totp.digits-picker")

        if let message = formViewModel.unsupportedTOTPDigitsMessage {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .accessibilityIdentifier("entry-edit.totp.digits-error")
        }

        Picker("Algorithm", selection: $formViewModel.totpAlgorithm) {
            Text(verbatim: "SHA-1").tag(TOTPAlgorithm.sha1)
            Text(verbatim: "SHA-256").tag(TOTPAlgorithm.sha256)
            Text(verbatim: "SHA-512").tag(TOTPAlgorithm.sha512)
        }
        .accessibilityIdentifier("entry-edit.totp.algorithm-picker")

        Button("Remove Verification Code", role: .destructive) {
            showRemoveTOTPConfirmation = true
        }
        .accessibilityIdentifier("entry-edit.totp.remove")
        // Anchored to the button for the same reason as the delete dialog.
        .confirmationDialog(
            "Remove Verification Code",
            isPresented: $showRemoveTOTPConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                formViewModel.removeTOTP()
                isManualTOTPEntryActive = false
                totpPeriodText = String(formViewModel.totpPeriod)
            }
            .accessibilityIdentifier("entry-edit.totp.remove-confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The verification code will no longer be generated for this entry.")
        }
    }

    /// Focus loss / submit for the period mirror: unparsable text snaps back
    /// to the committed value; valid input has already been committed by the
    /// text `onChange`.
    private func snapBackInvalidTOTPPeriodText() {
        if Int(totpPeriodText).map({ $0 > 0 }) != true {
            totpPeriodText = String(formViewModel.totpPeriod)
        }
    }

    /// The tags this entry already carries, one removable pill each, above the
    /// field. Nothing renders before the first tag lands, so a fresh entry
    /// opens on a plain field rather than an empty container.
    ///
    /// Declared an accessibility container for the same reason as the
    /// suggestion strip below — the pills keep their own identifiers.
    @ViewBuilder
    private var appliedTagStrip: some View {
        if formViewModel.tags.isEmpty == false {
            FlowLayout(spacing: 6) {
                ForEach(Array(formViewModel.tags.enumerated()), id: \.offset) { index, tag in
                    appliedTagChip(tag, fallbackIndex: index)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("entry-edit.tags")
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
            "entry-edit.tag.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: fallbackIndex))"
        )
    }

    /// The database's other tags, one tap each, wrapped under the tag field.
    /// Nothing at all renders when there is nothing left to offer — a database
    /// without tags, or an entry that already carries or inherits every one of
    /// them, shows the plain field with no empty husk below it.
    ///
    /// The strip carries a container identifier but is also declared an
    /// accessibility container, so the chips keep their own identifiers instead
    /// of inheriting the strip's (see `README.md`).
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
            .accessibilityIdentifier("entry-edit.tag-suggestions")
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
            "entry-edit.tag-suggestion.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: fallbackIndex))"
        )
    }

    private var navigationTitle: String {
        switch formViewModel.mode {
        case .create:
            String(localized: "New Entry")
        case .edit:
            String(localized: "Edit Entry")
        }
    }

    /// Creating an entry (new or duplicated) reads "Create", matching the New
    /// Database and New Group flows; editing an existing entry keeps "Save".
    private var confirmButtonTitle: String {
        switch formViewModel.mode {
        case .create:
            String(localized: "Create")
        case .edit:
            String(localized: "Save")
        }
    }

    /// Where a New Entry form will save. Only create mode has one: an entry
    /// being edited moves through the Move to Group flow instead.
    @ViewBuilder
    private var destinationGroupRow: some View {
        Button {
            showGroupPicker = true
        } label: {
            HStack {
                Label(destinationGroupName, systemImage: "folder")

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("entry-edit.group")
        .macHoverHighlight()
    }

    private var destinationGroupName: String {
        guard let groupID = formViewModel.createDestinationGroupID else { return "" }
        return databaseViewModel.group(withID: groupID)?.name ?? ""
    }

    private func basicFieldRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            content()
                .macLabelsHidden()
                .macFormFieldStyle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func cancelTapped() {
        if formViewModel.isDirty {
            showDiscardConfirmation = true
        } else {
            onComplete(.cancelled)
        }
    }

    private func saveTapped() {
        do {
            switch formViewModel.mode {
            case .create(let parentGroupID):
                try databaseViewModel.applyEntryEdit(
                    .createEntry(parentGroupID: parentGroupID, draft: formViewModel.entryDraftPayload)
                )
            case .edit(let entryID):
                try databaseViewModel.applyEntryEdit(
                    .updateEntry(entryID: entryID, draft: formViewModel.entryDraftPayload)
                )
            }

            isSubmitting = true
            Task { @MainActor in
                await databaseViewModel.saveHandlingError()
                isSubmitting = false
                if let saveError = databaseViewModel.saveError {
                    editingErrorMessage = saveError.localizedDescription
                    databaseViewModel.clearSaveError()
                } else {
                    finish(.saved)
                }
            }
        } catch {
            editingErrorMessage = error.localizedDescription
        }
    }

    /// See `EntryEditCompletionGate` for why a conflicted save does not close
    /// the editor right away.
    private func finish(_ completion: Completion) {
        if let completion = completionGate.finish(completion, hasSaveConflict: databaseViewModel.saveConflict != nil) {
            onComplete(completion)
        }
    }

    private var conflictHasSettled: Bool {
        EntryEditCompletionGate.isSettled(
            hasSaveConflict: databaseViewModel.saveConflict != nil,
            isPresentingMergeResult: databaseViewModel.mergeSummaryMessage != nil || databaseViewModel.mergeFailure != nil,
            isDirty: databaseViewModel.isDirty
        )
    }

    private func deleteTapped(sendToRecycleBin: Bool) {
        guard case .edit(let entryID) = formViewModel.mode else { return }

        do {
            try databaseViewModel.deleteEntry(entryID, sendToRecycleBin: sendToRecycleBin)
            isSubmitting = true
            Task { @MainActor in
                await databaseViewModel.saveHandlingError()
                isSubmitting = false
                if let saveError = databaseViewModel.saveError {
                    editingErrorMessage = saveError.localizedDescription
                    databaseViewModel.clearSaveError()
                } else {
                    finish(.deleted)
                }
            }
        } catch {
            editingErrorMessage = error.localizedDescription
        }
    }
}

/// Paste-friendly `otpauth://` enrollment: `onApply` parses and fills the
/// entry form, returning the parse error to surface inline instead of
/// applying anything.
private struct TOTPSetupLinkSheet: View {
    let onApply: (String) -> OTPAuthURIError?

    @Environment(\.dismiss) private var dismiss
    @State private var linkText = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField(text: $linkText, prompt: Text(verbatim: "otpauth://totp/…")) {
                    Text("Setup Link")
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("entry-edit.totp.link-field")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("entry-edit.totp.link-error")
                }
            }
            .navigationTitle("Enter Setup Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("entry-edit.totp.link-cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        applyTapped()
                    }
                    .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("entry-edit.totp.link-apply")
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
        .macSheetFrame(minWidth: 460, minHeight: 220)
    }

    private func applyTapped() {
        if let error = onApply(linkText) {
            errorMessage = Self.message(for: error)
        } else {
            dismiss()
        }
    }

    static func message(for error: OTPAuthURIError) -> String {
        switch error {
        case .notAnOTPAuthURI:
            String(localized: "This isn't an otpauth:// setup link.")
        case .unsupportedType:
            String(localized: "This setup link uses an unsupported code type. Only time-based (TOTP) codes are supported.")
        case .missingOrInvalidSecret:
            String(localized: "This setup link doesn't contain a valid secret.")
        case .invalidParameter:
            String(localized: "This setup link contains an invalid parameter.")
        }
    }
}
