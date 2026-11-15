#if os(macOS)
import SwiftUI

/// Content of the menu bar quick-search panel (`MacQuickSearchPanel`). Keyboard
/// handling lives in the panel's key monitor, so the search field keeps focus
/// while the arrow keys move the selection.
struct MacQuickSearchView: View {
    @Bindable var model: MacQuickSearchViewModel
    @FocusState private var isSearchFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private static let selectedPillIndent: CGFloat = 38

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
                    title: Text(MacQuickSearchViewModel.lockedTitle(databaseName: databaseName)),
                    message: nil,
                    action: Text("Unlock…")
                )
            case .unlocked(let databaseName):
                search(databaseName: databaseName)
            }
        }
        .frame(width: MacQuickSearchPanel.panelSize.width, height: MacQuickSearchPanel.panelSize.height)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.9),
            in: RoundedRectangle(cornerRadius: MacQuickSearchPanel.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacQuickSearchPanel.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
        )
    }

    private func handOff(systemImage: String, title: Text, message: Text?, action: Text) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            title
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            if let message {
                message
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                model.showDatabase()
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
        let results = model.results
        return VStack(spacing: 0) {
            searchField(databaseName: databaseName)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 2)

            HStack(spacing: 6) {
                Text(databaseName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("quick-search.database-name")
                Spacer(minLength: 8)
                if let count = model.resultCountText(for: results) {
                    Text(count)
                        .accessibilityIdentifier("quick-search.result-count")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)

            resultList(results)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .padding(.horizontal, 12)

            footer
        }
        .onAppear(perform: focusSearchField)
        .onChange(of: model.presentationID) { _, _ in
            focusSearchField()
        }
    }

    private func searchField(databaseName: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search \(databaseName)", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFieldFocused)
                .accessibilityIdentifier("quick-search.field")
            if let shortcutHint = model.shortcutHint {
                Text(verbatim: shortcutHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.accentColor.opacity(isSearchFieldFocused ? 0.35 : 0), lineWidth: 7)
        )
    }

    @ViewBuilder
    private func resultList(_ results: [MacQuickSearchViewModel.Result]) -> some View {
        if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Type to search this database.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else if results.isEmpty {
            Text("No Matching Entries")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            let selectedID = results.first { $0.id == model.selectedResultID }?.id ?? results.first?.id
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { result in
                            row(for: result, isSelected: result.id == selectedID)
                                .id(result.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
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

    private func row(for result: MacQuickSearchViewModel.Result, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                icon(for: result, isSelected: isSelected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.entry.title.isEmpty ? String(localized: "(untitled)") : result.entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                    let subtitle = model.subtitle(for: result)
                    if subtitle.isEmpty == false {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if isSelected {
                pills(for: result)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, isSelected ? 8 : 7)
        .padding(.bottom, isSelected ? 10 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: isSelected ? 9 : 8, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedResultID = result.id
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                model.selectedResultID = result.id
                model.perform(.primaryAction)
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Open in KeeForge")) {
            model.openInKeeForge(result)
        }
        .accessibilityIdentifier("quick-search.row")
    }

    /// Standard, custom and opt-in website icons, as everywhere else on Mac.
    private func icon(for result: MacQuickSearchViewModel.Result, isSelected: Bool) -> some View {
        FaviconView(
            url: result.entry.url,
            iconID: result.entry.iconID,
            size: 18,
            customIconData: model.customIconData(for: result)
        )
        .foregroundStyle(Color.primary)
        .frame(width: 28, height: 28)
        .background(
            isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.quaternary),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .environment(\.colorScheme, isSelected ? .light : colorScheme)
        .accessibilityHidden(true)
    }

    private func pills(for result: MacQuickSearchViewModel.Result) -> some View {
        let primary = model.primaryCopyField(for: result)
        let pills = Group {
            if model.canCopy(.username, from: result) {
                pill("Copy Username", isPrimary: primary == .username, identifier: "quick-search.copy-username") {
                    Task { await model.copy(.username, from: result) }
                }
            }
            if model.canCopy(.password, from: result) {
                pill("Copy Password", isPrimary: primary == .password, identifier: "quick-search.copy-password") {
                    Task { await model.copy(.password, from: result) }
                }
            }
            if model.canCopy(.verificationCode, from: result) {
                pill("Copy Code", isPrimary: false, identifier: "quick-search.copy-code") {
                    Task { await model.copy(.verificationCode, from: result) }
                }
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { pills }
                .padding(.leading, Self.selectedPillIndent)
            HStack(spacing: 6) { pills }
            VStack(alignment: .leading, spacing: 6) { pills }
        }
    }

    private func pill(
        _ title: LocalizedStringKey,
        isPrimary: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 24)
                .foregroundStyle(isPrimary ? Color.accentColor : Color.white)
                .background(isPrimary ? Color.white : Color.white.opacity(0.22), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
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
