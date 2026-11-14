#if os(macOS)
import AppKit
import SwiftUI

/// The Mac entry detail (Main, EntryVariants, LongText and ReadOnly boards): a header with the
/// icon, title, path and Edit, cards of label/value rows, and a footer with the dates and the
/// History link. Every value, reveal and copy comes from `MacEntryDetailModel`.
struct MacEntryDetailView: View {
    let model: MacEntryDetailModel
    @Bindable var viewModel: DatabaseViewModel
    let presentation: MacWorkspacePresentation
    let attachmentPreview: MacAttachmentPreviewController

    @State private var width: CGFloat = 600
    @State private var isShowingHistory = false
    @State private var isShowingIconPicker = false
    @State private var hasClosed = false

    private var entryID: UUID { model.source.entryID }
    private var metrics: MacDetailMetrics { .forWidth(width) }
    private var isEntryGone: Bool { viewModel.entry(withID: entryID) == nil }

    var body: some View {
        Group {
            if let entry = model.entry {
                ScrollView(.vertical) {
                    content(entry)
                        .padding(metrics.contentInsets)
                        .frame(maxWidth: MacDetailMetrics.maximumContentWidth, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                ContentUnavailableView(
                    "Entry Unavailable",
                    systemImage: "doc.badge.questionmark",
                    description: Text("This entry no longer exists in the current draft.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.macDetailMetrics, metrics)
        .background(MacDetailPalette.column)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear {
            model.appeared()
            closeIfGone()
        }
        .onDisappear { model.disappeared() }
        .onChange(of: isEntryGone) { closeIfGone() }
        .onChange(of: presentation.commandEditor == nil) { closeIfGone() }
        .onChange(of: presentation.copyFeedback.copied) { _, copied in
            guard let copied, copied.entryID == entryID else { return }
            AccessibilityNotification.Announcement(copied.field.copiedLabel).post()
        }
        .sheet(isPresented: $isShowingHistory) {
            EntryHistoryView(entryID: entryID, viewModel: viewModel)
                .macSheetFrame(minWidth: 760, minHeight: 520)
        }
        .sheet(isPresented: $isShowingIconPicker) {
            if let entry = viewModel.entry(withID: entryID) {
                EntryIconPickerView(
                    entryTitle: entry.title,
                    selection: Self.iconSelection(of: entry),
                    customIcons: viewModel.customIcons,
                    databaseViewModel: viewModel,
                    canDownloadFavicon: viewModel.canDownloadFavicon(forEntryID: entryID),
                    onSelect: { icon in changeEntryIcon(icon) },
                    onDownloadFavicon: {
                        try await viewModel.downloadFavicon(forEntryID: entryID)
                        // Outside the picker's cancellable task: the icon is in the draft by now.
                        await Task { await viewModel.saveHandlingError() }.value
                    }
                )
            }
        }
    }

    private func content(_ entry: KPEntry) -> some View {
        let fields = model.fields
        let main = fields.filter { [.username, .password, .verificationCode].contains($0.kind) || $0.kind.isWebsite }
        let passkey = fields.filter { $0.kind == .passkeyRelyingParty || $0.kind == .passkeyUsername }
        let custom = fields.filter(\.kind.isCustom)
        let notes = fields.first { $0.kind == .notes }
        let attachments = model.attachments
        let tags = model.tags
        let showsTags = tags.own.isEmpty == false || tags.inherited.isEmpty == false
        return VStack(alignment: .leading, spacing: metrics.sectionGap) {
            header(entry)
            if model.isExpired {
                Label("This entry has expired", systemImage: "exclamationmark.triangle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.State.danger)
                    .accessibilityIdentifier("entry-detail.expired-warning")
            }
            if main.isEmpty == false {
                MacDetailCard {
                    ForEach(Array(main.enumerated()), id: \.element.id) { index, field in
                        MacEntryFieldRow(field: field, model: model, isFirst: index == 0)
                    }
                }
            }
            if passkey.isEmpty == false {
                MacDetailCard {
                    MacPasskeyHeaderRow(relyingParty: model.passkeyRelyingParty ?? "")
                    ForEach(passkey) { field in
                        MacEntryFieldRow(field: field, model: model, isFirst: false)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Passkey"))
            }
            if custom.isEmpty == false {
                MacDetailCard {
                    ForEach(Array(custom.enumerated()), id: \.element.id) { index, field in
                        MacEntryFieldRow(field: field, model: model, isFirst: index == 0)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Custom Fields"))
            }
            if notes != nil || attachments.isEmpty == false || showsTags {
                MacDetailCard {
                    if let notes {
                        MacNotesRow(field: notes, model: model)
                    }
                    ForEach(attachments) { attachment in
                        MacAttachmentRow(
                            attachment: attachment, entryID: entryID, label: attachmentLabel(attachment, count: attachments.count),
                            controller: attachmentPreview, isFirst: notes == nil && attachment.index == 0
                        )
                    }
                    if showsTags {
                        MacTagsRow(tags: tags, isFirst: notes == nil && attachments.isEmpty) { tag in
                            viewModel.workspace.selectedTag = tag
                        }
                    }
                }
            }
            footer
        }
    }

    private func attachmentLabel(_ attachment: MacEntryDetailModel.Attachment, count: Int) -> String {
        guard attachment.index == 0 else { return "" }
        return count == 1 ? String(localized: "Attachment") : String(localized: "Attachments")
    }

    // MARK: - Header

    private func header(_ entry: KPEntry) -> some View {
        HStack(alignment: .center, spacing: metrics.headerGap) {
            iconButton(entry)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 12) {
                    Text(model.title.isEmpty ? String(localized: "(untitled)") : model.title)
                        .font(.largeTitle.bold())
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("entry-detail.title")
                    if viewModel.isReadOnly == false {
                        Button("Edit") {
                            presentation.beginEntryEdit(entryID: entryID, in: viewModel)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .disabled(DatabaseCommands(session: viewModel).canEditEntry == false)
                        .accessibilityIdentifier("entry-detail.edit")
                    }
                }
                MacEntryPathLine(components: model.pathComponents, modified: model.modified)
            }
        }
    }

    /// The icon opens the picker (saved at once) unless the database is read-only.
    @ViewBuilder
    private func iconButton(_ entry: KPEntry) -> some View {
        let icon = FaviconView(url: entry.url, iconID: entry.iconID, size: MacDetailMetrics.headerIconSize,
                               customIconData: viewModel.customIconData(for: entry))
        if viewModel.isReadOnly {
            icon
        } else {
            MacEntryIconButton(icon: icon) { isShowingIconPicker = true }
        }
    }

    private static func iconSelection(of entry: KPEntry) -> EntryIconSelection {
        if let uuid = entry.customIconUUID {
            return .custom(uuid: uuid)
        }
        return .standard(iconID: entry.iconID)
    }

    private func changeEntryIcon(_ icon: EntryIconSelection) {
        do {
            try viewModel.setEntryIcon(icon, entryID: entryID)
            Task { await viewModel.saveHandlingError() }
        } catch {
            viewModel.presentSaveError(error)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        FlowLayout(spacing: 6) {
            if let created = model.created {
                Text(MacEntryFormatting.created(created))
                Text(verbatim: "·")
            }
            expiryText
            if model.historyCount > 0 {
                Text(verbatim: "·")
                Button(String(localized: "\(model.historyCount) Earlier Versions")) {
                    isShowingHistory = true
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("entry-detail.history")
                .accessibilityValue(String(model.historyCount))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.leading, metrics.footerInset)
    }

    @ViewBuilder
    private var expiryText: some View {
        let text = Text(MacEntryFormatting.expiry(model.expiry))
        if model.expiry != nil {
            text
                .foregroundStyle(model.isExpired ? AnyShapeStyle(Theme.State.danger) : AnyShapeStyle(.secondary))
                .accessibilityIdentifier("entry-detail.expiry")
        } else {
            text
        }
    }

    // MARK: - Closing a deleted entry

    /// A vanished entry clears the selection, except under the editor, whose own completion
    /// (a permanent delete) closes it once the editor is gone.
    private func closeIfGone() {
        guard hasClosed == false, viewModel.state == .unlocked, isEntryGone,
              presentation.commandEditor == nil else { return }
        hasClosed = true
        if viewModel.workspace.selectedEntryID == entryID {
            viewModel.workspace.selectedEntryID = nil
        }
    }
}

// MARK: - Header pieces

/// The entry icon as a button; a pencil badge appears on hover.
private struct MacEntryIconButton<Icon: View>: View {
    let icon: Icon
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            icon
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .tint)
                        .font(.system(size: 20))
                        .background(Circle().fill(MacDetailPalette.column).padding(-2))
                        .offset(x: 4, y: 4)
                        .opacity(isHovering ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("entry-detail.icon-button")
        .accessibilityLabel("Icon")
        .accessibilityHint("Changes the entry icon")
        .macHelp(String(localized: "Changes the entry icon"))
    }
}

/// "Work › Development · Modified 3 days ago": the path gives way first, middle groups before the
/// first and last, and "Modified …" is never cut.
private struct MacEntryPathLine: View {
    let components: [String]
    let modified: Date?
    @State private var width: CGFloat = .infinity

    var body: some View {
        let modifiedText = modified.map { MacEntryFormatting.modified($0) }
        HStack(spacing: 0) {
            if let path = fittingPath(besides: modifiedText) {
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if modifiedText != nil {
                    Text(verbatim: " · ").fixedSize()
                }
            }
            if let modifiedText {
                Text(modifiedText)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The longest candidate that fits beside "· Modified …", measured in the body font.
    private func fittingPath(besides modifiedText: String?) -> String? {
        let candidates = MacEntryFormatting.pathCandidates(components)
        guard let last = candidates.last else { return nil }
        let font = NSFont.preferredFont(forTextStyle: .body)
        func measure(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let available = width - (modifiedText.map { measure(" · " + $0) } ?? 0)
        return candidates.first { measure($0) <= available } ?? last
    }
}
#endif
