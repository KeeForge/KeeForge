#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct UnlockView: View {
    @Bindable var viewModel: DatabaseViewModel
    let onBackToDatabaseList: () -> Void
    var showsChooseDifferentFileAction = true

    @State private var password = ""
    @State private var filePickerState = PickerPresentationState<FilePickerTarget>()
    @State private var selectionAlert: DocumentPickerService.SelectionAlert?
    @State private var keyFileData: Data?
    @State private var keyFileName: String?
    @State private var keyFileSelection = UnlockKeyFileSelection()
    @State private var keyFileSelectionTask: Task<Void, Never>?
    @State private var feedbackContext: FeedbackComposerContext?
    @State private var showRemoveMissingConfirmation = false
    @State private var copiedErrorDetails = false
    @State private var isPasswordVisible = false
    @FocusState private var passwordFocused: Bool
    @ScaledMetric(relativeTo: .body) private var keyFileNameMinimumWidth: CGFloat = 100
    @ScaledMetric(relativeTo: .body) private var unlockFieldHeight = Theme.Size.unlockField

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                contentSection
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(UnlockViewBackground())
        .scrollIndicators(.hidden)
        .databaseNavigationTitle(
            viewModel.databaseDisplayName,
            subtitle: SettingsSummaryText.joined([
                viewModel.databaseFilename,
                viewModel.databaseReference.cloudProviderKind?.displayName,
            ])
        )
        // One importer for both targets: SwiftUI does not reliably present a
        // second `.fileImporter` attached to the same view.
        .fileImporter(
            isPresented: Binding(
                get: { filePickerState.isPresented },
                set: { isPresented in
                    filePickerState.updatePresentation(isPresented)
                }
            ),
            allowedContentTypes: filePickerState.activeTarget?.allowedContentTypes
                ?? DocumentPickerService.keyFilePickerContentTypes,
            onCompletion: handleFilePickerSelection
        )
        .sheet(item: $feedbackContext) { context in
            FeedbackComposerView(context: context)
                .macSheetFrame()
        }
        .alert(item: $selectionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            loadUITestKeyFileIfNeeded()
        }
        .task {
            await loadAssociatedKeyFileIfNeeded()
        }
        .onChange(of: viewModel.openFailure?.errorCode) { _, _ in
            copiedErrorDetails = false
        }
        .onDisappear(perform: cancelPendingKeyFileSelection)
    }

    @ViewBuilder
    private var contentSection: some View {
        if let failure = viewModel.openFailure {
            failureSection(failure)

            if failure.canRetryUnlock {
                credentialsSection
            }
        } else if viewModel.hasSavedFile {
            credentialsSection
        } else {
            unavailableSection
        }
    }

    /// The field and its show/hide button.
    @ViewBuilder
    private var passwordInput: some View {
        Group {
            if isPasswordVisible {
                TextField("Enter password", text: $password)
            } else {
                SecureField("Enter password", text: $password)
            }
        }
        .passwordInputStyle()
        .focused($passwordFocused)
        .submitLabel(.go)
        .onSubmit(unlockWithPassword)
        .accessibilityIdentifier("unlock.password.field")

        Button {
            isPasswordVisible.toggle()
            passwordFocused = true
        } label: {
            Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPasswordVisible ? "Hide master password" : "Show master password")
        .accessibilityIdentifier("unlock.password-visibility-button")
        .macHelp(
            isPasswordVisible
                ? String(localized: "Hide master password")
                : String(localized: "Show master password")
        )
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.cardGap) {
            designedFieldLabel("Master Password")

            HStack(spacing: Theme.Spacing.iconText) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Theme.labelSecondary)
                    .accessibilityHidden(true)
                passwordInput
            }
            .padding(.horizontal, Theme.Spacing.side)
            .frame(minHeight: unlockFieldHeight)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(.tint, lineWidth: Theme.Size.focusRing)
                    .opacity(passwordFocused ? 1 : 0)
            }

            designedFieldLabel("Key File")

            VStack(spacing: 0) {
                designedKeyFileRow

                if viewModel.availableHardwareKeyTransports.isEmpty == false || viewModel.hardwareKey != nil {
                    Divider()
                    designedHardwareKeyRow
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

            VStack(spacing: Theme.Spacing.cardGap) {
                Button(action: unlockWithPassword) {
                    Label("Unlock Database", systemImage: "lock.open.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(hasKeyComponent == false || isUnlocking || keyFileSelection.isLoading)
                .accessibilityIdentifier("unlock.button")

                if viewModel.canUseBiometrics {
                    Button(action: unlockWithBiometrics) {
                        Label(viewModel.biometricLabel, systemImage: viewModel.biometricIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(isUnlocking)
                }

                if showsChooseDifferentFileAction {
                    Button("Choose Different File") {
                        onBackToDatabaseList()
                    }
                    .font(Theme.Font.subhead)
                    .accessibilityIdentifier("unlock.choose-different")
                }
            }
            .padding(.top, Theme.Spacing.textLine)
        }
    }

    private func designedFieldLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(Theme.Font.subhead.weight(.semibold))
            .foregroundStyle(Theme.labelSecondary)
            .padding(.leading, Theme.Spacing.side)
    }

    private var designedKeyFileRow: some View {
        // Stacks once the value and its controls cannot share a line.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.iconText) {
                Label {
                    keyFileValue
                        .frame(idealWidth: keyFileName == nil ? nil : keyFileNameMinimumWidth)
                } icon: {
                    Image(systemName: "doc")
                        .foregroundStyle(.tint)
                }

                Spacer(minLength: 0)

                keyFileClearButton
                keyFileSelectControls
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
                HStack(spacing: Theme.Spacing.iconText) {
                    keyFileValue
                    Spacer(minLength: 0)
                    keyFileClearButton
                }
                HStack(spacing: Theme.Spacing.iconText) {
                    keyFileSelectControls
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.side)
        .frame(minHeight: unlockFieldHeight)
    }

    private var designedHardwareKeyRow: some View {
        Menu {
            hardwareKeyMenuItems
        } label: {
            LabeledContent {
                HStack(spacing: Theme.Spacing.badgeGap) {
                    hardwareKeyValue
                    hardwareKeyChevron
                }
            } label: {
                Text("Hardware Key")
                    .foregroundStyle(Color.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("unlock.hardware-key.picker")
        .padding(.horizontal, Theme.Spacing.side)
        .frame(minHeight: unlockFieldHeight)
    }

    @ViewBuilder
    private func failureSection(_ failure: DatabaseOpenFailure) -> some View {
        if failure.canRetryUnlock {
            retryableFailureCard(failure)
        } else {
            designedFailureSection(failure)
        }
    }

    private func retryableFailureCard(_ failure: DatabaseOpenFailure) -> some View {
        UnlockFailureCard(failure: failure) {
            feedbackContext = .databaseOpenFailure(failure)
        }
    }

    /// The design's error page: what went wrong in words, the code as a row,
    /// the two ways forward, then the rest as links.
    private func designedFailureSection(_ failure: DatabaseOpenFailure) -> some View {
        VStack(spacing: Theme.Spacing.cardGap) {
            VStack(spacing: Theme.Spacing.badgeGap) {
                Image(systemName: failure.isAuthenticationFailure ? "lock.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(failure.isAuthenticationFailure ? Theme.danger : Theme.warning)
                    .frame(width: Theme.Size.failureBadge, height: Theme.Size.failureBadge)
                    .background(
                        failure.isAuthenticationFailure ? AnyShapeStyle(Theme.dangerSoft) : AnyShapeStyle(Theme.fill),
                        in: Circle()
                    )
                    .accessibilityHidden(true)

                Text(failure.title)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(failure.summary)
                    .font(Theme.Font.subhead)
                    .foregroundStyle(Theme.labelSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("unlock.error.label")
            }
            .frame(maxWidth: .infinity)

            LabeledContent("Error Code") {
                Text(failure.errorCode)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(Theme.labelSecondary)
            }
            .padding(Theme.Spacing.side)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

            Button(action: retryUnlock) {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("unlock.retry.button")

            if viewModel.canRelinkDatabaseFile {
                Button {
                    selectionAlert = nil
                    filePickerState.present(.databaseFile)
                } label: {
                    Label("Locate Database File", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("unlock.relink")
            }

            VStack(alignment: .leading, spacing: 0) {
                if failure.isAuthenticationFailure == false, showsChooseDifferentFileAction {
                    failureLink(
                        failure.canChooseDifferentFile ? "Choose Different File" : "Back to Database List",
                        systemImage: "folder",
                        identifier: "unlock.choose-different"
                    ) {
                        onBackToDatabaseList()
                    }
                    Divider()
                }
                failureLink("Copy Error Details", systemImage: "doc.on.doc", identifier: "unlock.copy-error") {
                    copyErrorDetails(failure)
                }
                Divider()
                failureLink("Send Feedback", systemImage: "paperplane", identifier: "unlock.send-feedback") {
                    feedbackContext = .databaseOpenFailure(failure)
                }
                if viewModel.canRemoveMissingDocumentsFile {
                    Divider()
                    removeMissingDocumentsLink
                }
            }
            .padding(.horizontal, Theme.Spacing.side)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

            Label(failure.privacyNote, systemImage: "shield.lefthalf.filled")
                .font(Theme.Font.footnote)
                .foregroundStyle(Theme.labelSecondary)

            if copiedErrorDetails {
                Text("Error details copied.")
                    .font(Theme.Font.footnote.weight(.medium))
                    .foregroundStyle(Theme.success)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unlock.error.card")
    }

    private func failureLink(
        _ title: LocalizedStringKey,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.navButton, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityIdentifier(identifier)
    }

    /// Its dialog stays on the button, so iPad anchors the popover to it.
    private var removeMissingDocumentsLink: some View {
        Button(role: .destructive) {
            showRemoveMissingConfirmation = true
        } label: {
            Label("Remove from List", systemImage: "trash")
                .frame(maxWidth: .infinity, minHeight: Theme.Size.navButton, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.danger)
        .accessibilityIdentifier("unlock.remove-missing")
        .confirmationDialog(
            "Remove Database?",
            isPresented: $showRemoveMissingConfirmation
        ) {
            Button("Remove", role: .destructive) {
                viewModel.removeMissingDocumentsDatabase()
                onBackToDatabaseList()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(viewModel.databaseDisplayName)” will be removed from KeeForge, including its cached copy and saved biometric key.")
        }
    }

    @ViewBuilder
    private var keyFileValue: some View {
        if let keyFileName {
            Text(keyFileName)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("None selected")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var keyFileClearButton: some View {
        if keyFileData != nil {
            Button {
                cancelPendingKeyFileSelection()
                keyFileData = nil
                keyFileName = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear key file")
            .accessibilityIdentifier("unlock.keyfile.clear")
            .macHelp(String(localized: "Clear key file"))
        }
    }

    @ViewBuilder
    private var keyFileSelectControls: some View {
        Button("Select") {
            selectionAlert = nil
            filePickerState.present(.keyFile)
        }
        .font(.subheadline)
        .accessibilityIdentifier("unlock.keyfile.select")

        if keyFileSelection.isLoading {
            ProgressView()
        }
    }

    @ViewBuilder
    private var hardwareKeyMenuItems: some View {
        Button {
            viewModel.setHardwareKey(nil)
        } label: {
            if viewModel.hardwareKey == nil {
                Label("None", systemImage: "checkmark")
            } else {
                Text("None")
            }
        }

        ForEach(hardwareKeyOptions, id: \.self) { option in
            Button {
                viewModel.setHardwareKey(option)
            } label: {
                if viewModel.hardwareKey == option {
                    Label(hardwareKeyTitle(option), systemImage: "checkmark")
                } else {
                    Text(hardwareKeyTitle(option))
                }
            }
        }
    }

    private var hardwareKeyValue: some View {
        Text(viewModel.hardwareKey.map(hardwareKeyTitle) ?? String(localized: "None"))
            .foregroundStyle(viewModel.hardwareKey == nil ? .secondary : .primary)
    }

    private var hardwareKeyChevron: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.subheadline)
            .foregroundStyle(.tint)
    }

    /// Every slot on each transport this device has, plus the stored choice
    /// even when this device lacks its transport, so the picker can show it.
    private var hardwareKeyOptions: [HardwareKeyConfiguration] {
        var options = viewModel.availableHardwareKeyTransports.flatMap { transport in
            HardwareKeyConfiguration.Slot.allCases.map { HardwareKeyConfiguration(transport: transport, slot: $0) }
        }
        if let current = viewModel.hardwareKey, options.contains(current) == false {
            options.append(current)
        }
        return options
    }

    private func hardwareKeyTitle(_ configuration: HardwareKeyConfiguration) -> String {
        switch (configuration.transport, configuration.slot) {
        case (.nfc, .one): String(localized: "YubiKey via NFC, Slot 1")
        case (.nfc, .two): String(localized: "YubiKey via NFC, Slot 2")
        }
    }

    private var unavailableSection: some View {
        VStack(spacing: 16) {
            Text("This database is unavailable. Return to the database list to remove it or refresh its bookmark.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if showsChooseDifferentFileAction {
                Button("Back to Database List") { onBackToDatabaseList() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var isUnlocking: Bool {
        if case .unlocking = viewModel.state { return true }
        return false
    }

    /// A YubiKey alone is a valid master key; KeePassXC allows it.
    private var hasKeyComponent: Bool {
        password.isEmpty == false || keyFileData != nil || viewModel.hardwareKey != nil
    }

    private func retryUnlock() {
        if hasKeyComponent {
            unlockWithPassword()
            return
        }

        if viewModel.canUseBiometrics, viewModel.openFailure?.canRetryQuickUnlock ?? true {
            unlockWithBiometrics()
            return
        }

        passwordFocused = true
    }

    private func copyErrorDetails(_ failure: DatabaseOpenFailure) {
        ClipboardService.copy(failure.copyableDetails)
        copiedErrorDetails = true
        HapticService.success()
    }

    private func unlockWithPassword() {
        guard hasKeyComponent, !keyFileSelection.isLoading else { return }
        Task {
            await viewModel.unlock(password: password, keyFileData: keyFileData)
            if case .unlocked = viewModel.state {
                password = ""
            }
        }
    }

    private func unlockWithBiometrics() {
        Task {
            switch await viewModel.unlockWithBiometrics() {
            case .passwordFallback, .promptUnavailable, .cancelled:
                // Nothing was unlocked and no prompt is coming;
                // hand focus to the password field so the tap visibly did
                // something.
                passwordFocused = true
            case .unlocked, .failed:
                break
            }
        }
    }

    private func loadAssociatedKeyFileIfNeeded() async {
        guard keyFileData == nil else { return }
        let selectionRevision = keyFileSelection.revision
        guard let associatedKeyFile = await viewModel.loadAssociatedKeyFile() else { return }
        guard !Task.isCancelled, keyFileData == nil,
              keyFileSelection.revision == selectionRevision else { return }
        keyFileData = associatedKeyFile.data
        keyFileName = associatedKeyFile.filename
    }

    private func loadUITestKeyFileIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing") else { return }
        guard keyFileData == nil else { return }
        let env = ProcessInfo.processInfo.environment
        guard let base64 = env["UI_TEST_KEYFILE_BASE64"], !base64.isEmpty,
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return }
        keyFileData = data
        keyFileName = env["UI_TEST_KEYFILE_FILENAME"] ?? "test.key"
        #endif
    }

    private func handleFilePickerSelection(_ result: Result<URL, Error>) {
        switch filePickerState.consumeActiveTarget() {
        case .keyFile:
            handleKeyFileSelection(result)
        case .databaseFile:
            handleDatabaseFileSelection(result)
        case nil:
            break
        }
    }

    private func handleDatabaseFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard DocumentPickerService.isSupportedDatabaseSelection(url) else {
                selectionAlert = DocumentPickerService.invalidDatabaseSelectionAlert()
                return
            }
            do {
                try viewModel.relinkDatabaseFile(to: url)
            } catch {
                selectionAlert = DocumentPickerService.fileAccessFailureAlert(for: error)
            }
        case .failure(let error):
            selectionAlert = DocumentPickerService.pickerFailureAlert(for: error)
        }
    }

    private func handleKeyFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            cancelPendingKeyFileSelection()
            keyFileData = nil
            keyFileName = nil
            keyFileSelectionTask = Task {
                guard let result = await keyFileSelection.read(url: url) else { return }
                keyFileSelectionTask = nil
                switch result {
                case .success(let data):
                    keyFileData = data
                    keyFileName = url.lastPathComponent
                case .failure(let error):
                    selectionAlert = DocumentPickerService.fileAccessFailureAlert(for: error)
                }
            }
        case .failure(let error):
            selectionAlert = DocumentPickerService.pickerFailureAlert(for: error)
        }
    }

    private func cancelPendingKeyFileSelection() {
        keyFileSelectionTask?.cancel()
        keyFileSelectionTask = nil
        keyFileSelection.cancel()
    }
}

private enum FilePickerTarget {
    case keyFile
    case databaseFile

    var allowedContentTypes: [UTType] {
        switch self {
        case .keyFile:
            DocumentPickerService.keyFilePickerContentTypes
        case .databaseFile:
            DocumentPickerService.databasePickerContentTypes
        }
    }
}

struct DatabaseOpeningView: View {
    let databaseName: String
    var filename: String? = nil
    let statusMessage: String
    var progress: Double? = nil
    var onCancel: (() -> Void)? = nil
    var step: DatabaseViewModel.OpeningStep = .decrypting
    var provider: CloudProviderKind? = nil
    var isCloudBacked = false

    /// Titled like the unlock page, so neither hand-over moves the name.
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                        if index > 0 {
                            Divider().padding(.leading, 44)
                        }
                        OpeningStepRow(step: item)
                    }
                }
                .padding(.horizontal, Theme.Spacing.side)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                if let onCancel {
                    // Only a hardware key prompt can be cancelled; it says what to do.
                    Text(statusMessage)
                        .font(Theme.Font.subhead)
                        .foregroundStyle(Theme.labelSecondary)
                        .multilineTextAlignment(.center)

                    Button(action: onCancel) {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .accessibilityIdentifier("unlock.hardware-key.cancel")
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 20)
            // The unlock page's content width, so both pages line up.
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(UnlockViewBackground())
        .databaseNavigationTitle(databaseName, subtitle: sourceLine ?? "")
    }

    private var sourceLine: String? {
        let line = SettingsSummaryText.joined([
            filename == databaseName ? nil : filename,
            provider?.displayName,
        ])
        return line.isEmpty ? nil : line
    }

    private var steps: [DatabaseOpeningSteps.Step] {
        DatabaseOpeningSteps.make(step: step, isCloudBacked: isCloudBacked, provider: provider, progress: progress)
    }
}

extension DatabaseOpeningView {
    init(viewModel: DatabaseViewModel, onCancel: (() -> Void)? = nil) {
        self.init(
            databaseName: viewModel.databaseDisplayName,
            filename: viewModel.databaseFilename,
            statusMessage: viewModel.unlockStatusMessage,
            progress: viewModel.cloudSyncProgress,
            onCancel: onCancel,
            step: viewModel.openingStep,
            provider: viewModel.databaseReference.cloudProviderKind,
            isCloudBacked: viewModel.databaseReference.isCloudBacked
        )
    }
}

/// One step of the opening screen: done, in progress, or still to come.
private struct OpeningStepRow: View {
    let step: DatabaseOpeningSteps.Step

    var body: some View {
        HStack(spacing: Theme.Spacing.iconText) {
            indicator
                .frame(width: 28, height: 28)
            Text(step.title)
                .font(.body)
                .foregroundStyle(step.state == .upcoming ? Theme.labelSecondary : Color.primary)
            Spacer(minLength: 0)
            if let detail = step.detail {
                Text(detail)
                    .font(Theme.Font.subhead.monospacedDigit())
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var indicator: some View {
        switch step.state {
        case .done:
            Image(systemName: "checkmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.tileGlyph)
                .frame(width: 28, height: 28)
                .background(Theme.State.success, in: Circle())
                .accessibilityLabel(Text("Done"))
        case .current:
            ProgressView()
                .controlSize(.small)
        case .upcoming:
            Circle()
                .strokeBorder(Theme.labelSecondary.opacity(0.4), lineWidth: 2)
        }
    }
}

/// Grouped, so the design's cards sit on it.
struct UnlockViewBackground: View {
    var body: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
    }
}

extension View {
    /// The unlock and opening pages' title: the database's name over its file
    /// and storage, centred in the navigation bar.
    func databaseNavigationTitle(_ name: String, subtitle: String) -> some View {
        navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(name)
                            .font(.headline)
                        if subtitle.isEmpty == false {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(Theme.labelSecondary)
                        }
                    }
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
            }
    }
}

/// A failure the unlock form can fix, such as a wrong password: what went
/// wrong, above the fields, with Unlock as the retry.
struct UnlockFailureCard: View {
    let failure: DatabaseOpenFailure
    let onSendFeedback: () -> Void

    var body: some View {
        let tint = failure.isAuthenticationFailure ? Theme.danger : Theme.warning
        return HStack(alignment: .top, spacing: Theme.Spacing.iconText) {
            Image(systemName: failure.isAuthenticationFailure ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.badgeGap) {
                Text(failure.title)
                    .font(.title3.weight(.bold))

                Text(failure.summary)
                    .font(.body)
                    .accessibilityIdentifier("unlock.error.label")

                Text(failure.errorCode)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.labelSecondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            Menu {
                Button("Send Feedback", systemImage: "paperplane") {
                    onSendFeedback()
                }
                .accessibilityIdentifier("unlock.send-feedback")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .frame(minWidth: Theme.Size.navButton, minHeight: Theme.Size.navButton, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Error Options")
        }
        .padding(Theme.Spacing.side)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            failure.isAuthenticationFailure ? AnyShapeStyle(Theme.dangerSoft) : AnyShapeStyle(Theme.warning.opacity(0.14)),
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unlock.error.card")
    }
}
#endif
