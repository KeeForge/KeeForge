#if os(macOS)
import SwiftUI

/// Content of the menu bar quick-search panel (`MacQuickSearchPanel`). Keyboard
/// handling lives in the panel's key monitor, so the search field keeps focus
/// while the arrow keys move the selection.
struct MacQuickSearchView: View {
    @Bindable var model: MacQuickSearchViewModel
    @FocusState private var isSearchFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch model.content {
            case .noDatabase:
                handOff(
                    systemImage: "tray",
                    title: Text("No Database Open"),
                    message: Text("Choose a database in KeeForge to search it from here."),
                    action: Text("Choose Database…")
                )
            case .locked(let databaseName):
                handOff(
                    systemImage: "lock.fill",
                    title: Text(databaseName),
                    message: Text("Unlock this database in KeeForge to search it from here."),
                    action: Text("Unlock…")
                )
            case .unlocked(let databaseName):
                search(databaseName: databaseName)
            }
        }
        .frame(width: MacQuickSearchPanel.panelSize.width, height: MacQuickSearchPanel.panelSize.height)
        .accessibilityIdentifier("quick-search.panel")
    }

    private func handOff(systemImage: String, title: Text, message: Text, action: Text) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            title
                .font(.headline)
                .multilineTextAlignment(.center)
            message
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                model.showMainWindow()
            } label: {
                action
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("quick-search.open-main-window")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func search(databaseName: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search \(databaseName)", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFieldFocused)
                    .accessibilityIdentifier("quick-search.field")
            }
            .padding(12)

            Divider()

            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
        .onAppear(perform: focusSearchField)
        .onChange(of: model.presentationID) { _, _ in
            focusSearchField()
        }
    }

    @ViewBuilder
    private var results: some View {
        let results = model.results
        if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Type to search this database.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if results.isEmpty {
            Text("No Matching Entries")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let selectedID = results.first { $0.id == model.selectedEntryID }?.id ?? results.first?.id
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { entry in
                            row(for: entry, isSelected: entry.id == selectedID)
                                .id(entry.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selectedID) { _, newValue in
                    guard let newValue else { return }
                    if reduceMotion {
                        proxy.scrollTo(newValue)
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(newValue) }
                    }
                }
            }
            .accessibilityIdentifier("quick-search.results")
        }
    }

    private func row(for entry: KPEntry, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            EntryRow(
                entry: entry,
                username: model.username(for: entry),
                customIconData: model.customIconData(for: entry),
                folderPath: model.folderPath(for: entry)
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected {
                rowActions(for: entry)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedEntryID = entry.id
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                model.selectedEntryID = entry.id
                model.perform(.primaryAction)
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("quick-search.row")
    }

    @ViewBuilder
    private func rowActions(for entry: KPEntry) -> some View {
        if model.canCopy(.username, from: entry) {
            actionButton("Copy Username", systemImage: "person", identifier: "quick-search.copy-username") {
                Task { await model.copy(.username, from: entry) }
            }
        }
        if model.canCopy(.password, from: entry) {
            actionButton("Copy Password", systemImage: "key", identifier: "quick-search.copy-password") {
                Task { await model.copy(.password, from: entry) }
            }
        }
        if model.canCopy(.verificationCode, from: entry) {
            actionButton("Copy Verification Code", systemImage: "clock", identifier: "quick-search.copy-code") {
                Task { await model.copy(.verificationCode, from: entry) }
            }
        }
        actionButton("Open in KeeForge", systemImage: "arrow.up.forward.app", identifier: "quick-search.open-entry") {
            model.openInKeeForge(entry)
        }
    }

    private func actionButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Label {
                Text("Copy")
            } icon: {
                Text(verbatim: "↩")
            }
            Label {
                Text("Open in KeeForge")
            } icon: {
                Text(verbatim: "⌘↩")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The panel only becomes key as it is shown, so focus is requested on the
    /// next turn rather than during the same update.
    private func focusSearchField() {
        Task { @MainActor in
            isSearchFieldFocused = true
        }
    }
}
#endif
