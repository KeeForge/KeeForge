import CryptoKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct EntryDetailView: View {
    let entryID: UUID
    @Bindable var viewModel: DatabaseViewModel
    var onClose: () -> Void = {}
    /// Routes a tapped tag chip in shells that select instead of push (the iPad
    /// workspace, whose detail column has no browsing stack of its own, and
    /// macOS, which selects the tag in its sidebar). Left nil in the compact
    /// shell, where chips push `DatabaseRoute.tag` like any other row.
    var onSelectTag: ((String) -> Void)? = nil
    /// False in the selection-driven shells (iPad detail column, macOS), where
    /// this screen is the detail root and closing means clearing the selection:
    /// their `dismiss` has nothing of this screen's to pop, so it bubbles out
    /// to the split view and pops the *sidebar's* navigation stack instead.
    var popsOnClose: Bool = true
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var activeEditor: EntryEditViewModel?
    /// Set when the editor completes a delete; the close then finishes in
    /// `onAppear`, a separate transaction from the editor pop (see `body`).
    @State private var closesAfterEditorDismissal = false
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
        let icon = Group {
            if PlatformDesign.followsIOSDesign {
                FaviconEntryIconView(
                    entry: entry,
                    customIconData: viewModel.customIconData(for: entry),
                    size: headerIconSize
                )
            } else {
                FaviconView(
                    url: entry.url,
                    iconID: entry.iconID,
                    size: 40,
                    customIconData: viewModel.customIconData(for: entry)
                )
            }
        }

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
            .macHelp(String(localized: "Changes the entry icon"))
        }
    }

    /// The "this can be edited" cue on the icon: a small pencil badge, in the
    /// same spot as the one on an editable avatar in Contacts. The ring is the
    /// row's own colour so the badge reads as sitting on the row, not the icon.
    private var editBadge: some View {
        Image(systemName: "pencil.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .tint)
            .font(.system(size: 18))
            .background(Circle().fill(editBadgeRing).padding(-2))
            .offset(x: 6, y: 6)
            .accessibilityHidden(true)
    }

    /// The iOS header sits on the screen's ground, the macOS one on a row.
    private var editBadgeRing: Color {
        PlatformDesign.followsIOSDesign ? Color(.systemGroupedBackground) : Color(.secondarySystemGroupedBackground)
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

    /// macOS states the read-only condition once, in the window toolbar the
    /// workspace owns. This screen's toolbar merges into that same bar, so
    /// repeating it here put two indicators side by side in one toolbar.
    private var showsReadOnlyIndicator: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// The regular layouts keep `CloudSyncControls` beside this view, and
    /// those already carry the cached-copy warning.
    private var showsCloudSyncWarning: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

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
                            FieldRow(
                                label: String(localized: "Username"),
                                value: viewModel.resolvingFieldReferences(entry.username),
                                icon: "person.fill",
                                accessibilityKey: "username",
                                isCardRow: PlatformDesign.followsIOSDesign
                            )
                        }

                        if entry.hasPassword {
                            PasswordFieldRow(
                                password: entry.password,
                                sessionKey: sessionKey,
                                secretAccess: viewModel.secretAccess,
                                resolveReferences: viewModel.resolvingFieldReferences,
                                isCurrent: secretActionIsCurrent,
                                isCardRow: PlatformDesign.followsIOSDesign
                            )
                        }

                        if !entry.url.isEmpty {
                            URLFieldRow(
                                url: viewModel.resolvingFieldReferences(entry.url),
                                isCardRow: PlatformDesign.followsIOSDesign
                            )
                        }

                        ForEach(Array(entry.additionalURLs.enumerated()), id: \.offset) { index, url in
                            URLFieldRow(
                                url: viewModel.resolvingFieldReferences(url),
                                label: String(localized: "URL \(index + 2)"),
                                isCardRow: PlatformDesign.followsIOSDesign
                            )
                        }

                        if let totpConfig = entry.totpConfig {
                            TOTPSection(
                                config: totpConfig,
                                sessionKey: sessionKey,
                                isCardRow: PlatformDesign.followsIOSDesign
                            )
                        }
                    }

                    if !entry.notes.isEmpty {
                        Section("Notes") {
                            SelectableNotesText(viewModel.resolvingFieldReferences(entry.notes))
                                .accessibilityIdentifier("entry.notes")
                        }
                    }

                    if let passkey = entry.passkeyCredential {
                        Section("Passkey") {
                            FieldRow(label: String(localized: "Relying Party"), value: passkey.relyingParty, icon: "person.badge.key.fill", accessibilityKey: "relying_party", isCardRow: PlatformDesign.followsIOSDesign)
                            FieldRow(label: String(localized: "Username"), value: passkey.username, icon: "person.fill", accessibilityKey: "username", isCardRow: PlatformDesign.followsIOSDesign)
                        }
                    }

                    let customFields = EntryEditViewModel.orderedCustomFieldsOutsideURLRows(of: entry)
                    if !customFields.isEmpty {
                        Section("Custom Fields") {
                            ForEach(customFields, id: \.key) { key, value in
                                if entry.protectedStringKeys.contains(key) {
                                    ProtectedFieldRow(
                                        label: key,
                                        value: viewModel.resolvingFieldReferences(value),
                                        secretAccess: viewModel.secretAccess,
                                        showsInlineLabel: true,
                                        isCurrent: secretActionIsCurrent
                                    )
                                } else {
                                    FieldRow(
                                        label: key,
                                        value: viewModel.resolvingFieldReferences(value),
                                        icon: "text.justify.left",
                                        showsInlineLabel: true
                                    )
                                }
                            }
                        }
                    }

                    if !entry.attachments.isEmpty {
                        AttachmentsSection(entryID: entry.id, attachments: entry.attachments, viewModel: viewModel)
                    }

                    if PlatformDesign.followsIOSDesign {
                        detailsCard(for: entry)
                    } else {
                        tagsSection

                        if entry.creationTime != nil ||
                            entry.lastModificationTime != nil ||
                            entry.enabledExpiryTime != nil {
                            Section("Details") {
                                if let created = entry.creationTime {
                                    LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .shortened))
                                }
                                if let modified = entry.lastModificationTime {
                                    LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
                                }
                                if let expiry = entry.enabledExpiryTime {
                                    LabeledContent("Expires", value: expiry.formatted(date: .abbreviated, time: .shortened))
                                        .accessibilityIdentifier("entry-detail.expiry")
                                }
                            }
                        }
                        if !entry.history.isEmpty {
                            Section {
                                historyButton(for: entry) {
                                    Text(entry.history.count, format: .number)
                                        .foregroundStyle(.secondary)
                                } label: {
                                    Label("History", systemImage: "clock.arrow.circlepath")
                                }
                            }
                        }
                    }
                }
                .modifier(EntryDetailTitle(title: entry.title))
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
                                    activeEditor = EntryEditViewModel(
                                        editing: currentEntry,
                                        sessionKey: currentSessionKey,
                                        knownTags: viewModel.tagsInDisplayOrder,
                                        inheritedTags: viewModel.inheritedTags(forEntryID: entryID)
                                    )
                                }
                                .accessibilityIdentifier("entry-detail.edit")
                            } else if showsReadOnlyIndicator {
                                ReadOnlyIndicator(explanation: viewModel.readOnlyExplanation)
                            }
                        }
                    }
                }
                .sheet(isPresented: $isShowingHistory) {
                    EntryHistoryView(entryID: entryID, viewModel: viewModel)
                        .macSheetFrame(minWidth: 760, minHeight: 520)
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
                    guard activeEditor == nil else { return }
                    finishClose()
                }
            }
        }
        // Outside the entry branch: a permanent delete removes the entry while
        // the editor is the topmost pushed view, and a branch-scoped
        // `navigationDestination` would be torn down with no way to pop it.
        .modifier(EntryEditorPresentation(view: self))
        // Re-fires when the pushed editor pops back. The close must wait for
        // this later transaction — popping the editor and this screen together
        // drops the second pop on iOS 26. `entry == nil` catches an editor
        // dismissed any other way (e.g. cancelled) over a vanished entry.
        .onAppear {
            let editorJustPopped = closesAfterEditorDismissal
            closesAfterEditorDismissal = false
            if editorJustPopped || (activeEditor == nil && entry == nil) {
                finishClose()
            }
        }
    }

    /// iOS: the icon with its title below it, on the screen's ground. macOS: a
    /// row with the icon beside the title.
    @ViewBuilder
    private func header(for entry: KPEntry) -> some View {
        let title = Text(entry.title.isEmpty ? String(localized: "(untitled)") : entry.title)
            .accessibilityIdentifier("entry-detail.title")
        if PlatformDesign.followsIOSDesign {
            Section {
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
        } else {
            Section {
                HStack {
                    iconButton(for: entry)
                    title
                        .font(.title2.bold())
                }
            }
        }
    }

    /// Above the fields of an expired entry. Editing the entry clears it; the
    /// banner has no action of its own.
    @ViewBuilder
    private func expiryBanner(for entry: KPEntry) -> some View {
        if PlatformDesign.followsIOSDesign {
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
        } else {
            Section {
                Label("This entry has expired", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.State.danger)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("entry-detail.expired-warning")
            }
        }
    }

    private func expiryColor(isExpired: Bool) -> Color {
        isExpired ? Theme.danger : Theme.labelSecondary
    }

    /// iPhone only: on iPad the sidebar's Lock sits right beside this screen.
    private var showsLockButton: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    /// iOS: where the entry lives, its tags, dates and history in one card.
    /// An expired entry's footer says how to clear the banner.
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
        } footer: {
            if entry.isExpired(), viewModel.isReadOnly == false {
                Text("Set a new expiry date, or turn expiry off, under Edit.")
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

    /// The entry's own tags, then the ones it carries only because of where it
    /// sits. Both come from `detailTags(forEntryID:)`, the same list the tag
    /// index is built from, so browsing to a tag can never land on an entry
    /// whose chips fail to explain the match.
    ///
    /// An inherited tag belongs to the group, not the entry, and is edited in
    /// `GroupEditView`. Its outlined folder pill distinguishes it from an
    /// entry-owned tag without adding a second caption above the strip.
    @ViewBuilder
    private var tagsSection: some View {
        let tags = viewModel.detailTags(forEntryID: entryID)
        if tags.own.isEmpty == false || tags.inherited.isEmpty == false {
            Section("Tags") {
                if tags.own.isEmpty == false {
                    FlowLayout(spacing: 6) {
                        // Enumerated for the identifier fallback index, which
                        // is what gives an emoji-only tag — one that normalizes
                        // to nothing — a usable identifier.
                        ForEach(Array(tags.own.enumerated()), id: \.offset) { index, tag in
                            tagChip(tag, fallbackIndex: index)
                        }
                    }
                }

                if tags.inherited.isEmpty == false {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(tags.inherited.enumerated()), id: \.offset) { index, tag in
                            inheritedTagChip(tag, fallbackIndex: index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Declared a container, like the editor's tag strips, so
                    // the chips keep their own identifiers instead of
                    // inheriting this one (see `AGENTS.md`).
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("entry-detail.inherited-tags")
                }
            }
        }
    }

    /// One tag capsule, a shortcut into that tag's filtered entry list. Follows
    /// the link-or-callback shape the row helpers elsewhere use, so the compact
    /// stack pushes while the iPad and macOS shells route through their own
    /// browsing surface.
    @ViewBuilder
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

    /// Presents the entry editor. iOS pushes onto the navigation stack;
    /// macOS presents a sheet (navigation-stack pushes inside the split-view
    /// columns misrender on macOS).
    private struct EntryEditorPresentation: ViewModifier {
        let view: EntryDetailView

        func body(content: Content) -> some View {
            #if os(macOS)
            content
                .sheet(item: view.$activeEditor) { formViewModel in
                    NavigationStack {
                        editor(formViewModel)
                    }
                    .macSheetFrame()
                }
            #else
            content
                .navigationDestination(item: view.$activeEditor) { formViewModel in
                    editor(formViewModel)
                }
            #endif
        }

        private func editor(_ formViewModel: EntryEditViewModel) -> some View {
            EntryEditView(
                formViewModel: formViewModel,
                databaseViewModel: view.viewModel
            ) { completion in
                view.activeEditor = nil
                if completion == .deleted {
                    // iOS pops only the editor here; `onAppear` in `body`
                    // finishes the close once the pop lands. macOS sheets never
                    // re-fire the presenter's `onAppear`, so close directly.
                    #if os(macOS)
                    view.finishClose()
                    #else
                    view.closesAfterEditorDismissal = true
                    #endif
                }
            }
        }
    }
}

/// Titles the entry screen per shell: iOS pushes it, so the entry's title is the
/// inline navigation title. macOS renders it in the split view's detail column,
/// which is the innermost `navigationTitle`/`navigationSubtitle` in the window
/// and would therefore rename the whole window — Window menu, Mission Control,
/// window switcher, screenshots — after a secret-bearing entry name. The window
/// title belongs to the database (`RegularDatabaseWorkspaceView.macSplitView`)
/// and its subtitle to the content column's group, tag, or search context
/// (`MacEntriesColumn`, `TagEntriesView`), so the Mac side titles nothing here;
/// the entry's own name is already the header of this screen.
private struct EntryDetailTitle: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        #if os(macOS)
        content
        #else
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// The capsule label shared by both chip shapes here and by the entry editor's
/// suggestion strip, so a tag looks the same wherever it is tappable.
/// `systemImage` is nil on this screen, where a chip navigates to the tag, and
/// `plus` in the editor, where it adds the tag to the field.
struct TagCapsule: View {
    let tag: String
    var systemImage: String? = nil
    /// Drawn after the name instead of before it. The editor's removable pills
    /// use it so the affordance reads as "tag, then remove" rather than
    /// "action, then tag" the way the leading `plus` suggestions do.
    var trailingSystemImage: String? = nil
    /// Outlines the capsule instead of filling it, for a chip that is not the
    /// entry's own to change: the detail screen's inherited group tags.
    var isOutlined: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
            }

            Text(tag)
                .lineLimit(1)
                .truncationMode(.tail)

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            if isOutlined {
                Capsule().strokeBorder(.tertiary)
            } else if PlatformDesign.followsIOSDesign {
                Capsule().fill(Theme.accentSoft)
            } else {
                Capsule().fill(.fill)
            }
        }
    }

    private var foreground: AnyShapeStyle {
        if isOutlined {
            return AnyShapeStyle(HierarchicalShapeStyle.secondary)
        }
        return PlatformDesign.followsIOSDesign ? AnyShapeStyle(.tint) : AnyShapeStyle(HierarchicalShapeStyle.primary)
    }
}

#if os(iOS)
struct SelectableNotesText: UIViewRepresentable {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.text = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .label
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else {
            return nil
        }

        let fittingSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(fittingSize)
        return CGSize(width: width, height: size.height)
    }
}
#else
/// The macOS counterpart of the UIKit wrapper above: a non-editable, selectable
/// `NSTextView` that reports a width-aware height and turns URLs and email
/// addresses in a note into clickable links.
struct SelectableNotesText: NSViewRepresentable {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    /// Holds the TextKit 1 stack's storage. `NSLayoutManager` does not keep its
    /// text storage alive, so without this the storage would be deallocated the
    /// moment `makeNSView` returned.
    @MainActor
    final class Coordinator {
        let textStorage = NSTextStorage()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        // Built explicitly rather than through `NSTextView(frame:)`, which
        // opts into TextKit 2 — whose `layoutManager` is nil, and sizing below
        // needs one.
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        context.coordinator.textStorage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.textStorage.setAttributedString(Self.attributedNotes(text))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width < CGFloat.greatestFiniteMagnitude,
              let textContainer = nsView.textContainer,
              let layoutManager = nsView.layoutManager else {
            return nil
        }

        textContainer.containerSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return CGSize(width: width, height: ceil(layoutManager.usedRect(for: textContainer).height))
    }

    /// Plain body text with detected URLs and email addresses marked as links.
    static func attributedNotes(_ text: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.preferredFont(forTextStyle: .body),
                .foregroundColor: NSColor.labelColor,
            ]
        )

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }

        let range = NSRange(location: 0, length: (text as NSString).length)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url else { continue }
            attributed.addAttribute(.link, value: url, range: match.range)
        }
        return attributed
    }
}
#endif

// MARK: - Field Rows

/// iOS gathers an entry's fields into one card of label/value rows; on macOS
/// each field is a section of its own.
struct EntryFieldsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if PlatformDesign.followsIOSDesign {
            Section {
                content
            }
        } else {
            content
        }
    }
}

struct FieldRow: View {
    let label: String
    let value: String
    let icon: String
    // Locale-independent copy-button ID; defaults to the normalized label so
    // user-defined custom field keys keep their existing identifiers.
    var accessibilityKey: String?
    /// Identifier namespace for the copy control, matching `PasswordFieldRow`.
    var accessibilityPrefix: String = "entry"
    /// Custom fields already sit inside a shared section. Keeping their label
    /// in the row avoids nesting `Section` views, which gives SwiftUI
    /// inconsistent separator insets.
    var showsInlineLabel: Bool = false
    /// A label/value row inside a card the caller supplies (iOS).
    var isCardRow: Bool = false

    @ViewBuilder
    var body: some View {
        if isCardRow {
            LabeledContent {
                HStack(spacing: 0) {
                    Text(value)
                        .foregroundStyle(Theme.labelSecondary)
                        .textSelection(.enabled)
                    CopyButton(text: value, accessibilityID: "\(accessibilityPrefix).copy.\(normalizedLabel)")
                }
            } label: {
                Text(label)
            }
        } else if showsInlineLabel {
            VStack(alignment: .leading, spacing: 6) {
                inlineLabel
                fieldContent
            }
        } else {
            Section(label) {
                fieldContent
            }
        }
    }

    private var inlineLabel: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var fieldContent: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(value)
                .textSelection(.enabled)
            Spacer()
            CopyButton(text: value, accessibilityID: "\(accessibilityPrefix).copy.\(normalizedLabel)")
        }
    }

    private var normalizedLabel: String {
        accessibilityKey ?? label.lowercased().replacingOccurrences(of: " ", with: "_")
    }
}

struct ProtectedFieldRow: View {
    let label: String
    let value: String
    let secretAccess: SecretAccessGate
    var accessibilityPrefix: String = "entry"
    var showsInlineLabel: Bool = false
    var isCurrent: @MainActor () -> Bool
    @State private var revealed = false
    @State private var secretAction = EntrySecretAction()

    @ViewBuilder
    var body: some View {
        Group {
            if showsInlineLabel {
                VStack(alignment: .leading, spacing: 6) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    fieldContent
                }
            } else {
                Section(label) {
                    fieldContent
                }
            }
        }
        .onChange(of: value) { invalidateReveal() }
        .onDisappear { invalidateReveal() }
    }

    private var fieldContent: some View {
        HStack {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .frame(width: 24)

            if revealed {
                Text(value)
                    .font(.body.monospaced())
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                PasswordConcealedText(accessibilityLabel: String(localized: "Hidden protected field"))
            }

            Spacer(minLength: 12)

            Button(action: toggleReveal) {
                Image(systemName: revealed ? "eye.slash.fill" : "eye.fill")
                    .font(.body)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .disabled(secretAction.isAuthenticating)
            .accessibilityIdentifier("\(accessibilityPrefix).protected-field.\(normalizedLabel).reveal")
            .macHelp(revealed ? String(localized: "Hide \(label)") : String(localized: "Show \(label)"))

            CopyButton(
                text: value,
                secretAccess: secretAccess,
                authenticationReason: String(localized: "Copy protected field"),
                accessibilityID: "\(accessibilityPrefix).copy.\(normalizedLabel)",
                secretAction: secretAction,
                isCurrent: isCurrent
            )
        }
    }

    private var normalizedLabel: String {
        label.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    private func toggleReveal() {
        if revealed {
            HapticService.tap()
            revealed = false
            return
        }

        guard !secretAction.isAuthenticating, isCurrent() else { return }
        if secretAccess.requiresAuthentication {
            secretAction.perform(
                authenticate: {
                    try await secretAccess.authenticate(reason: String(localized: "View protected field"))
                },
                isCurrent: isCurrent,
                disclose: {
                    HapticService.success()
                    revealed = true
                }
            )
        } else {
            HapticService.tap()
            revealed = true
        }
    }

    private func invalidateReveal() {
        secretAction.invalidate()
        revealed = false
    }
}

struct PasswordFieldRow: View {
    let password: EncryptedValue
    let sessionKey: SymmetricKey
    let secretAccess: SecretAccessGate
    /// Applied to the decrypted plaintext before it is shown or copied, so a
    /// `{REF:…}` password reads and copies as the value it points at.
    var resolveReferences: (String) -> String = { $0 }
    /// Identifier namespace for the reveal and copy controls. Defaults to the live
    /// entry detail's long-standing `entry.*` ids; the history viewer passes its own
    /// so the two screens never contribute the same identifier to one hierarchy.
    var accessibilityPrefix: String = "entry"
    var isCurrent: @MainActor () -> Bool
    /// A label/value row inside a card the caller supplies (iOS).
    var isCardRow: Bool = false
    @State private var revealed = false
    @State private var revealedText: String?
    @State private var secretAction = EntrySecretAction()

    var body: some View {
        Group {
            if isCardRow {
                cardRow
            } else {
                Section("Password") {
                    PasswordDisplayRow(revealedText: revealed ? revealedText : nil) {
                        actions
                    }
                }
            }
        }
        .onChange(of: password) {
            secretAction.invalidate()
            refreshRevealedPassword()
        }
        .onChange(of: sessionKey) { invalidateReveal() }
        .onAppear { refreshRevealedPassword() }
        .onDisappear {
            secretAction.invalidate()
            revealedText = nil
        }
    }

    /// Concealed, the dots sit beside the label; revealed, the password takes
    /// the full width below it, with its strength underneath. One container
    /// for both: in a `List` a changed top-level view is a new row, whose
    /// `onDisappear`/`onAppear` would clear and reload the reveal forever.
    private var cardRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.iconText) {
            if revealed, let revealedText {
                Text("Password")
                    .font(Theme.Font.footnote)
                    .foregroundStyle(Theme.labelSecondary)
                HStack(spacing: 0) {
                    // No `.textSelection(.enabled)`: CopyButton is the only copy path.
                    PasswordDisplayText(revealedText)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Spacing.iconText)
                    actions
                }
                PasswordStrengthIndicator(password: revealedText)
            } else {
                LabeledContent {
                    HStack(spacing: 0) {
                        PasswordConcealedText()
                        actions
                    }
                } label: {
                    Text("Password")
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(action: toggleReveal) {
            Image(systemName: revealed ? "eye.slash.fill" : "eye.fill")
                .font(.body)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .buttonStyle(.borderless)
        .disabled(secretAction.isAuthenticating)
        .accessibilityLabel(revealTooltip)
        .accessibilityIdentifier("\(accessibilityPrefix).password.reveal")
        .macHelp(revealTooltip)

        CopyButton(
            resolveText: { plaintext(of: password) },
            secretAccess: secretAccess,
            accessibilityID: "\(accessibilityPrefix).copy.password",
            secretAction: secretAction,
            isCurrent: isCurrent
        )
    }

    /// Reuses the parameterized Show/Hide strings the password input row uses.
    private var revealTooltip: String {
        let field = String(localized: "Password")
        return revealed ? String(localized: "Hide \(field)") : String(localized: "Show \(field)")
    }

    private func plaintext(of value: EncryptedValue) -> String {
        resolveReferences((try? value.decrypt(using: sessionKey)) ?? "")
    }

    private func toggleReveal() {
        if revealed {
            HapticService.tap()
            revealed = false
            revealedText = nil
        } else {
            authenticateAndReveal()
        }
    }

    private func authenticateAndReveal() {
        guard !secretAction.isAuthenticating, isCurrent() else { return }
        // Gate on device-owner authentication (biometrics OR passcode/login
        // password/Apple Watch), not on biometrics availability: a Mac
        // without Touch ID or an iPhone without enrolled Face ID must still
        // prompt for the login password/passcode instead of revealing with a
        // single unauthenticated click. Auth is skipped only inside the
        // authentication grace period, or when the device has no protection
        // configured at all.
        if secretAccess.requiresAuthentication {
            secretAction.perform(
                authenticate: {
                    try await secretAccess.authenticate(reason: String(localized: "View password"))
                },
                isCurrent: isCurrent,
                disclose: {
                    HapticService.success()
                    revealedText = plaintext(of: password)
                    revealed = true
                }
            )
        } else {
            HapticService.tap()
            revealedText = plaintext(of: password)
            revealed = true
        }
    }

    private func invalidateReveal() {
        secretAction.invalidate()
        revealed = false
        revealedText = nil
    }

    private func refreshRevealedPassword() {
        guard revealed, isCurrent() else {
            revealedText = nil
            return
        }
        revealedText = plaintext(of: password)
    }
}

struct URLFieldRow: View {
    let url: String
    var label: String = String(localized: "URL")
    /// A stacked row inside a card the caller supplies (iOS): a URL rarely fits
    /// beside its label.
    var isCardRow: Bool = false
    @Environment(\.openURL) private var openURL

    @ViewBuilder
    var body: some View {
        if isCardRow {
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
        } else {
            Section(label) {
                HStack {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text(url)
                        .textSelection(.enabled)
                    Spacer()
                    actions
                }
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

struct CopyButton: View {
    private let resolveText: () -> String
    /// Set for a protected value: the copy then waits on this gate.
    var secretAccess: SecretAccessGate?
    var authenticationReason: String = String(localized: "Copy password")
    let accessibilityID: String
    private let sharedSecretAction: EntrySecretAction?
    private let isCurrent: @MainActor () -> Bool
    @State private var localSecretAction = EntrySecretAction()
    @State private var copied = false
    @State private var copyFeedbackID = UUID()

    private var secretAction: EntrySecretAction { sharedSecretAction ?? localSecretAction }

    init(
        text: String,
        secretAccess: SecretAccessGate? = nil,
        authenticationReason: String = String(localized: "Copy password"),
        accessibilityID: String,
        secretAction: EntrySecretAction? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) {
        self.init(
            resolveText: { text },
            secretAccess: secretAccess,
            authenticationReason: authenticationReason,
            accessibilityID: accessibilityID,
            secretAction: secretAction,
            isCurrent: isCurrent
        )
    }

    init(
        resolveText: @escaping () -> String,
        secretAccess: SecretAccessGate? = nil,
        authenticationReason: String = String(localized: "Copy password"),
        accessibilityID: String,
        secretAction: EntrySecretAction? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) {
        self.resolveText = resolveText
        self.secretAccess = secretAccess
        self.authenticationReason = authenticationReason
        self.accessibilityID = accessibilityID
        self.sharedSecretAction = secretAction
        self.isCurrent = isCurrent
    }

    var body: some View {
        Button {
            // Same device-owner gate as password reveal: biometrics when
            // available, passcode/login password/Apple Watch fallback
            // otherwise. Skipped only inside the authentication grace period,
            // or when the device has no protection.
            guard isCurrent() else { return }
            if let secretAccess, secretAccess.requiresAuthentication {
                secretAction.perform(
                    authenticate: {
                        try await secretAccess.authenticate(reason: authenticationReason)
                    },
                    isCurrent: isCurrent,
                    disclose: performCopy
                )
            } else {
                performCopy()
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.body)
                .foregroundStyle(copied ? Theme.State.success : Color.accentColor)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .buttonStyle(.borderless)
        .disabled(secretAction.isAuthenticating)
        .accessibilityIdentifier(accessibilityID)
        .macHelp(String(localized: "Copy"))
        .onDisappear {
            secretAction.invalidate()
            copied = false
        }
        .task(id: copyFeedbackID) {
            guard copied else { return }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            copied = false
        }
    }

    private func performCopy() {
        ClipboardService.copy(resolveText())
        copied = true
        copyFeedbackID = UUID()
        HapticService.success()
    }
}

// MARK: - TOTP Section

struct TOTPSection: View {
    let config: TOTPConfig
    let sessionKey: SymmetricKey
    /// Identifier namespace, matching `FieldRow` / `PasswordFieldRow`.
    var accessibilityPrefix: String = "entry"
    /// A label/value row inside a card the caller supplies (iOS).
    var isCardRow: Bool = false
    @State private var totpVM: TOTPViewModel
    @ScaledMetric(relativeTo: .title3) private var cardRingSize = Theme.Size.badge

    init(config: TOTPConfig, sessionKey: SymmetricKey, accessibilityPrefix: String = "entry", isCardRow: Bool = false) {
        self.config = config
        self.sessionKey = sessionKey
        self.accessibilityPrefix = accessibilityPrefix
        self.isCardRow = isCardRow
        self._totpVM = State(initialValue: TOTPViewModel(config: config, sessionKey: sessionKey))
    }

    var body: some View {
        Group {
            if isCardRow {
                LabeledContent {
                    HStack(spacing: Theme.Spacing.tileGap) {
                        CountdownRing(progress: totpVM.progress, seconds: totpVM.secondsRemaining, showsSeconds: false)
                            .frame(width: cardRingSize, height: cardRingSize)
                            .accessibilityLabel(Text("\(totpVM.secondsRemaining) seconds remaining"))
                        Text(totpVM.code)
                            .font(Theme.Font.codeRow)
                            .foregroundStyle(.tint)
                            .contentTransition(.numericText())
                            .accessibilityIdentifier("\(accessibilityPrefix).totp.code")
                        CopyButton(text: totpVM.code, accessibilityID: "\(accessibilityPrefix).copy.totp")
                    }
                } label: {
                    Text("One-Time Password")
                }
            } else {
                Section("One-Time Password") {
                    HStack {
                        CountdownRing(progress: totpVM.progress, seconds: totpVM.secondsRemaining)
                            .frame(width: 40, height: 40)

                        Text(totpVM.code)
                            .font(.title.monospaced().bold())
                            .contentTransition(.numericText())
                            .accessibilityIdentifier("\(accessibilityPrefix).totp.code")

                        Spacer()

                        CopyButton(text: totpVM.code, accessibilityID: "\(accessibilityPrefix).copy.totp")
                    }
                }
            }
        }
        .onAppear {
            updateTOTP()
            totpVM.start()
        }
        .onChange(of: config.secret) { updateTOTP() }
        .onChange(of: config.decodedSecret) { updateTOTP() }
        .onChange(of: config.period) { updateTOTP() }
        .onChange(of: config.digits) { updateTOTP() }
        .onChange(of: config.algorithm) { updateTOTP() }
        .onChange(of: sessionKey) { updateTOTP() }
        .onDisappear { totpVM.stop() }
    }

    private func updateTOTP() {
        totpVM.update(config: config, sessionKey: sessionKey)
    }
}

struct CountdownRing: View {
    let progress: Double
    let seconds: Int
    /// Off where the ring is too small to hold the number and the caller
    /// prints it beside the ring instead.
    var showsSeconds = true

    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: 3)
                .foregroundStyle(.quaternary)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .foregroundStyle(progress > 0.3 ? Theme.State.success : Theme.State.warning)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)

            if showsSeconds {
                Text("\(seconds)")
                    .font(.caption2.monospacedDigit())
            }
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            // The measured size, not `.unspecified`: a subview clamped to the
            // row width has to be handed that width to render its truncation.
            subviews[index].place(
                at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }

    /// A subview wider than the row is clamped to the row rather than allowed
    /// to overhang: wrapping cannot save it (it is alone on its line), so
    /// without the clamp it reports a width past the proposal and drags the
    /// whole container — in a `Form`, the enclosing row and its label — wider
    /// than the layout it sits in. A long tag is the realistic case.
    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (offsets: [CGPoint], sizes: [CGSize], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var sizes: [CGSize] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: currentX, y: currentY))
            sizes.append(size)
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
            // `currentX` carries the trailing spacing for the next subview;
            // the row's own right edge is that spacing back.
            maxX = max(maxX, currentX - spacing)
        }

        return (offsets, sizes, CGSize(width: maxX, height: currentY + rowHeight))
    }
}
