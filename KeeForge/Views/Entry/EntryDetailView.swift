#if os(iOS)
import CryptoKit
import SwiftUI

/// The iPhone and iPad entry detail. The Mac detail is `MacEntryDetailView`.
struct EntryDetailView: View {
    let entryID: UUID
    @Bindable var viewModel: DatabaseViewModel
    var onClose: () -> Void = {}
    /// Routes a tapped tag chip in the iPad workspace, whose detail column has
    /// no browsing stack of its own and selects instead of pushing. Left nil in
    /// the compact shell, where chips push `DatabaseRoute.tag` like any other row.
    var onSelectTag: ((String) -> Void)? = nil
    /// False in the iPad detail column, where this screen is the detail root and closing means clearing the selection:
    /// their `dismiss` has nothing of this screen's to pop, so it bubbles out
    /// to the split view and pops the *sidebar's* navigation stack instead.
    var popsOnClose: Bool = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Both `onAppear`s in `body` can fire on the same reveal, and each
    /// `dismiss()` would pop one navigation level.
    @State private var hasFinishedClosing = false
    @State private var isShowingHistory = false
    @State private var isShowingIconPicker = false
    @ScaledMetric(relativeTo: .title) private var headerIconSize = Theme.Size.entryHeaderIcon

    /// Clears the regular shells' selection and pops this screen, at most once.
    private func finishClose() {
        guard hasFinishedClosing == false else { return }
        hasFinishedClosing = true
        onClose()
        if popsOnClose {
            dismiss()
        }
    }

    private var entry: KPEntry? {
        viewModel.entry(withID: entryID)
    }

    /// What the entry displays today, which is what the picker opens on. A
    /// `<CustomIconUUID>` outranks `<IconID>` in KeePass, so the custom icon
    /// wins here for the same reason it wins on screen.
    private static func iconSelection(of entry: KPEntry) -> EntryIconSelection {
        if let uuid = entry.customIconUUID {
            return .custom(uuid: uuid)
        }
        return .standard(iconID: entry.iconID)
    }

    /// The entry's icon, opening the picker when the database can take the edit.
    ///
    /// Read-only databases render the same icon as a plain image: a button that
    /// only ever reports "this database is read-only" is a worse answer than not
    /// offering the affordance.
    @ViewBuilder
    private func iconButton(for entry: KPEntry) -> some View {
        let icon = FaviconEntryIconView(
            entry: entry,
            customIconData: viewModel.customIconData(for: entry),
            size: headerIconSize
        )

        if viewModel.isReadOnly {
            icon
        } else {
            Button {
                isShowingIconPicker = true
            } label: {
                icon
                    .overlay(alignment: .bottomTrailing) {
                        editBadge
                    }
                    // Room for the badge's overhang so it doesn't touch the title.
                    .padding(.trailing, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("entry-detail.icon-button")
            .accessibilityLabel("Icon")
            .accessibilityHint("Changes the entry icon")
        }
    }

    /// The "this can be edited" cue on the icon: a small pencil badge, in the
    /// same spot as the one on an editable avatar in Contacts. The ring is the
    /// screen's ground so the badge reads as sitting on it, not on the icon.
    private var editBadge: some View {
        Image(systemName: "pencil.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .tint)
            .font(.system(size: 18))
            .background(Circle().fill(Color(.systemGroupedBackground)).padding(-2))
            .offset(x: 6, y: 6)
            .accessibilityHidden(true)
    }

    private func changeEntryIcon(_ icon: EntryIconSelection) {
        do {
            try viewModel.setEntryIcon(icon, entryID: entryID)
            Task {
                await viewModel.saveHandlingError()
            }
        } catch {
            viewModel.presentSaveError(error)
        }
    }

    private var sessionKey: SymmetricKey? {
        viewModel.sessionKey
    }

    private var secretActionIsCurrent: @MainActor () -> Bool {
        EntrySecretAction.currentSession(viewModel)
    }

    private var showsCloudSyncWarning: Bool { horizontalSizeClass == .compact }

    var body: some View {
        Group {
            if let entry, let sessionKey {
                List {
                    header(for: entry)

                    if entry.isExpired() {
                        expiryBanner(for: entry)
                    }

                    EntryFieldsCard {
                        if !entry.username.isEmpty {
                            ReferenceAwareFieldRow(label: String(localized: "Username"), raw: entry.username,
                                                   viewModel: viewModel, isCurrent: secretActionIsCurrent) { username in
                                FieldRow(
                                    label: String(localized: "Username"),
                                    value: username,
                                    icon: "person.fill",
                                    accessibilityKey: "username",
                                    isCardRow: true
                                )
                            }
                        }

                        if entry.hasPassword {
                            PasswordFieldRow(
                                password: entry.password,
                                sessionKey: sessionKey,
                                secretAccess: viewModel.secretAccess,
                                resolveReferences: viewModel.resolvingFieldReferencesIncludingProtectedValues,
                                isCurrent: secretActionIsCurrent,
                                isCardRow: true
                            )
                        }

                        if !entry.url.isEmpty {
                            ReferenceAwareFieldRow(label: String(localized: "URL"), raw: entry.url,
                                                   viewModel: viewModel, isCurrent: secretActionIsCurrent) { url in
                                URLFieldRow(url: url)
                            }
                        }

                        ForEach(Array(entry.additionalURLs.enumerated()), id: \.offset) { index, url in
                            ReferenceAwareFieldRow(label: String(localized: "URL \(index + 2)"), raw: url,
                                                   viewModel: viewModel, isCurrent: secretActionIsCurrent) { url in
                                URLFieldRow(url: url, label: String(localized: "URL \(index + 2)"))
                            }
                        }

                        if let totpConfig = entry.totpConfig {
                            TOTPSection(
                                config: totpConfig,
                                sessionKey: sessionKey,
                                isCardRow: true
                            )
                        }
                    }

                    if !entry.notes.isEmpty {
                        ReferenceAwareFieldRow(label: String(localized: "Notes"), raw: entry.notes,
                                               viewModel: viewModel, isCurrent: secretActionIsCurrent) { notes in
                            Section("Notes") {
                                SelectableNotesText(notes)
                                    .accessibilityIdentifier("entry.notes")
                            }
                        }
                    }

                    if let passkey = entry.passkeyCredential {
                        Section("Passkey") {
                            FieldRow(label: String(localized: "Relying Party"), value: passkey.relyingParty, icon: "person.badge.key.fill", accessibilityKey: "relying_party", isCardRow: true)
                            FieldRow(label: String(localized: "Username"), value: passkey.username, icon: "person.fill", accessibilityKey: "username", isCardRow: true)
                        }
                    }

                    let customFields = EntryEditViewModel.orderedCustomFieldsOutsideURLRows(of: entry)
                    if !customFields.isEmpty {
                        Section("Custom Fields") {
                            ForEach(customFields, id: \.key) { key, value in
                                if entry.protectedStringKeys.contains(key) {
                                    ProtectedFieldRow(
                                        label: key,
                                        value: value,
                                        secretAccess: viewModel.secretAccess,
                                        resolveReferences: viewModel.resolvingFieldReferencesIncludingProtectedValues,
                                        showsInlineLabel: true,
                                        isCardRow: true,
                                        isCurrent: secretActionIsCurrent
                                    )
                                } else {
                                    ReferenceAwareFieldRow(label: key, raw: value, viewModel: viewModel,
                                                           showsInlineLabel: true,
                                                           isCurrent: secretActionIsCurrent) { value in
                                        FieldRow(
                                            label: key,
                                            value: value,
                                            icon: "text.justify.left",
                                            showsInlineLabel: true,
                                            isCardRow: true
                                        )
                                    }
                                }
                            }
                        }
                    }

                    if !entry.attachments.isEmpty {
                        AttachmentsSection(entryID: entry.id, attachments: entry.attachments, viewModel: viewModel)
                    }

                    detailsCard(for: entry)
                }
                .navigationTitle(entry.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            if showsCloudSyncWarning, let warningText = viewModel.cloudSyncBannerText {
                                CloudSyncWarningButton(message: warningText)
                            }

                            if showsLockButton {
                                Button {
                                    viewModel.lockRequest(manuallyTriggered: true)
                                } label: {
                                    Image(systemName: "lock.fill")
                                }
                                .accessibilityLabel("Lock")
                                .accessibilityIdentifier("lock.button")
                            }

                            if viewModel.isReadOnly == false {
                                Button("Edit") {
                                    guard let currentEntry = viewModel.entry(withID: entryID),
                                          let currentSessionKey = viewModel.sessionKey else { return }
                                    let editor = EntryEditViewModel(
                                        editing: currentEntry,
                                        sessionKey: currentSessionKey,
                                        knownTags: viewModel.tagsInDisplayOrder,
                                        inheritedTags: viewModel.inheritedTags(forEntryID: entryID)
                                    )
                                    viewModel.workspace.present(.entry(editor))
                                }
                                .accessibilityIdentifier("entry-detail.edit")
                            } else {
                                ReadOnlyIndicator(explanation: viewModel.readOnlyExplanation)
                            }
                        }
                    }
                }
                .sheet(isPresented: $isShowingHistory) {
                    EntryHistoryView(entryID: entryID, viewModel: viewModel)
                }
                .sheet(isPresented: $isShowingIconPicker) {
                    EntryIconPickerView(
                        entryTitle: entry.title,
                        selection: Self.iconSelection(of: entry),
                        customIcons: viewModel.customIcons,
                        databaseViewModel: viewModel,
                        canDownloadFavicon: viewModel.canDownloadFavicon(forEntryID: entryID),
                        onSelect: { icon in changeEntryIcon(icon) },
                        onDownloadFavicon: {
                            try await viewModel.downloadFavicon(forEntryID: entryID)
                            // Outside the picker's cancellable task on purpose:
                            // the icon is in the draft by now, and closing the
                            // sheet mid-save would leave it unwritten.
                            await Task { await viewModel.saveHandlingError() }.value
                        }
                    )
                }
            } else {
                ContentUnavailableView(
                    "Entry Unavailable",
                    systemImage: "doc.badge.questionmark",
                    description: Text("This entry no longer exists in the current draft.")
                )
                .onAppear {
                    // Mid-editor the vanished entry is the editor's own doing
                    // (permanent delete): its completion drives the close, so
                    // the editor pops cleanly after the save instead of being
                    // torn down mid-flight. On the iPad detail root this
                    // onAppear fires even while the editor covers it.
                    guard isEditorOpen == false else { return }
                    finishClose()
                }
            }
        }
        // An editor dismissed over a vanished entry (e.g. cancelled after a
        // sync removed it). A compact delete pops this screen with its editor.
        .onAppear {
            if isEditorOpen == false && entry == nil {
                finishClose()
            }
        }
    }

    private var isEditorOpen: Bool {
        viewModel.workspace.openEditor != nil
    }

    /// The icon with its title below it, on the screen's ground.
    private func header(for entry: KPEntry) -> some View {
        let title = Text(entry.title.isEmpty ? String(localized: "(untitled)") : entry.title)
            .accessibilityIdentifier("entry-detail.title")
        return Section {
                VStack(spacing: Theme.Spacing.cardGap) {
                    iconButton(for: entry)
                    VStack(spacing: Theme.Spacing.textLine) {
                        title
                            .font(Theme.Font.entryTitle)
                            .multilineTextAlignment(.center)
                        if let modified = entry.lastModificationTime {
                            Text("Last modified \(modified.formatted(date: .abbreviated, time: .omitted))")
                                .font(Theme.Font.subhead)
                                .foregroundStyle(Theme.labelSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
    }

    /// Above the fields of an expired entry. Editing the entry clears it; the
    /// banner has no action of its own.
    private func expiryBanner(for entry: KPEntry) -> some View {
        Section {
                HStack(spacing: Theme.Spacing.iconText) {
                    Label("This entry has expired", systemImage: "clock.badge.exclamationmark")
                        .font(.body.weight(.semibold))
                    Spacer(minLength: 0)
                    if let expiry = entry.enabledExpiryTime {
                        Text(expiry.formatted(date: .abbreviated, time: .omitted))
                            .font(Theme.Font.subhead)
                    }
                }
                .foregroundStyle(Theme.danger)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("entry-detail.expired-warning")
                .listRowBackground(Theme.dangerSoft)
        }
    }

    private func expiryColor(isExpired: Bool) -> Color {
        isExpired ? Theme.danger : Theme.labelSecondary
    }

    private var showsLockButton: Bool { horizontalSizeClass == .compact }

    /// Where the entry lives, its tags, dates and history in one card.
    private func detailsCard(for entry: KPEntry) -> some View {
        let tags = viewModel.detailTags(forEntryID: entryID)
        return Section {
            if let groupID = viewModel.parentGroupID(forEntryID: entryID),
               let path = viewModel.folderPath(forEntryID: entryID), path.isEmpty == false {
                groupRow(groupID: groupID, path: path)
            }

            if tags.own.isEmpty == false || tags.inherited.isEmpty == false {
                LabeledContent("Tags") {
                    VStack(alignment: .trailing, spacing: Theme.Spacing.badgeGap) {
                        if tags.own.isEmpty == false {
                            FlowLayout(spacing: Theme.Spacing.badgeGap) {
                                ForEach(Array(tags.own.enumerated()), id: \.offset) { index, tag in
                                    tagChip(tag, fallbackIndex: index)
                                }
                            }
                        }
                        if tags.inherited.isEmpty == false {
                            FlowLayout(spacing: Theme.Spacing.badgeGap) {
                                ForEach(Array(tags.inherited.enumerated()), id: \.offset) { index, tag in
                                    inheritedTagChip(tag, fallbackIndex: index)
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("entry-detail.inherited-tags")
                        }
                    }
                }
            }

            if let created = entry.creationTime {
                LabeledContent("Created") {
                    Text(created.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(Theme.labelSecondary)
                }
            }

            if let expiry = entry.enabledExpiryTime {
                LabeledContent("Expires") {
                    Text(expiry.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(expiryColor(isExpired: entry.isExpired()))
                }
                .accessibilityIdentifier("entry-detail.expiry")
            }

            if !entry.history.isEmpty {
                historyButton(for: entry) {
                    HStack(spacing: Theme.Spacing.badgeGap) {
                        Text("\(entry.history.count) versions")
                            .foregroundStyle(Theme.labelSecondary)
                        disclosureChevron
                    }
                } label: {
                    Text("History")
                        .foregroundStyle(Color.primary)
                }
            }
        }
    }

    /// Opens the group in the compact stack. The selection-driven shells have
    /// no browsing stack beside the detail, so there the row only names it.
    @ViewBuilder
    private func groupRow(groupID: UUID, path: String) -> some View {
        let value = Text(path)
            .foregroundStyle(Theme.labelSecondary)
            .lineLimit(1)
            .truncationMode(.head)
        if onSelectTag == nil {
            Button {
                viewModel.workspace.navigationPath.append(.group(groupID))
            } label: {
                LabeledContent {
                    HStack(spacing: Theme.Spacing.badgeGap) {
                        value
                        disclosureChevron
                    }
                } label: {
                    Text("Group")
                        .foregroundStyle(Color.primary)
                }
            }
            .accessibilityIdentifier("entry-detail.group")
        } else {
            LabeledContent {
                value
            } label: {
                Text("Group")
            }
            .accessibilityIdentifier("entry-detail.group")
        }
    }

    private var disclosureChevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func historyButton<Value: View, Title: View>(
        for entry: KPEntry,
        @ViewBuilder value: () -> Value,
        @ViewBuilder label: () -> Title
    ) -> some View {
        Button {
            isShowingHistory = true
        } label: {
            LabeledContent {
                value()
            } label: {
                label()
            }
        }
        .accessibilityIdentifier("entry-detail.history")
        // Count as the element's value, so automation reads it without
        // parsing the locale-formatted label.
        .accessibilityValue(String(entry.history.count))
    }

    /// One tag capsule, a shortcut into that tag's filtered entry list. Follows
    /// the link-or-callback shape the row helpers elsewhere use, so the compact
    /// stack pushes while the iPad shell routes through its own browsing surface.
    /// A `Button` in every shell, never a `NavigationLink`, even where the chip
    /// does push. All the chips share one `List` row, and a row containing
    /// several `NavigationLink`s misbehaves badly: the row — not the chip —
    /// owns the link, so a tap activates the wrong destination (observed: the
    /// last chip in the row) or several at once, and the row draws the
    /// selection background whenever any chip's value sits on the navigation
    /// path, greying the whole card. Pushing by hand keeps the chips
    /// independent, and drops the per-chip disclosure chevron with it.
    private func tagChip(_ tag: String, fallbackIndex: Int) -> some View {
        Button {
            if let onSelectTag {
                onSelectTag(tag)
            } else {
                viewModel.workspace.navigationPath.append(.tag(tag))
            }
        } label: {
            TagCapsule(tag: tag)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            "entry-detail.tag.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: fallbackIndex))"
        )
    }

    /// A tag the entry gets from an ancestor group: same destination as its own
    /// chips, drawn outlined rather than filled so the two read apart at a
    /// glance, and labelled for VoiceOver, which reaches a chip without the
    /// caption above the strip.
    private func inheritedTagChip(_ tag: String, fallbackIndex: Int) -> some View {
        Button {
            if let onSelectTag {
                onSelectTag(tag)
            } else {
                viewModel.workspace.navigationPath.append(.tag(tag))
            }
        } label: {
            TagCapsule(tag: tag, systemImage: "folder", isOutlined: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(tag), from a group"))
        .accessibilityIdentifier(
            "entry-detail.inherited-tag.\(TagAccessibility.identifierSuffix(for: tag, fallbackIndex: fallbackIndex))"
        )
    }
}

/// A stacked row inside the fields card: a URL rarely fits beside its label.
struct URLFieldRow: View {
    let url: String
    var label: String = String(localized: "URL")
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.textLine) {
            Text(label)
                .font(Theme.Font.footnote)
                .foregroundStyle(Theme.labelSecondary)
            HStack(spacing: 0) {
                Text(url)
                    .foregroundStyle(.tint)
                    .textSelection(.enabled)
                Spacer(minLength: Theme.Spacing.iconText)
                actions
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let link = URL(string: url) {
            Button {
                HapticService.tap()
                openURL(link)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.body)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .buttonStyle(.borderless)
            .accessibilityLabel("Open URL")
            .accessibilityIdentifier("entry.url.open")
        }
        CopyButton(text: url, accessibilityID: "entry.copy.url")
    }
}
#endif
