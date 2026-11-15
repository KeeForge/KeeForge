import AppKit
import SwiftUI

struct MacIconPickerView: View {
    @Bindable var model: MacIconPickerModel
    var database: DatabaseViewModel?
    var download: (() -> Void)?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.purpose == .entry {
                    HStack(spacing: 10) {
                        Button("Download Website Icon") { download?() }
                            .disabled(model.websiteHost == nil || model.isDownloading)
                            .accessibilityIdentifier("entry-icon-picker.download-favicon")
                        if let host = model.websiteHost {
                            Text("From \(host), through DuckDuckGo").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if database != nil {
                            Button("Manage Custom Icons…") { isManaging = true }
                                .accessibilityIdentifier("entry-icon-picker.manage")
                        }
                    }
                }
                if !model.customIcons.isEmpty {
                    Text("Custom Icons").font(.headline)
                    LazyVGrid(columns: columns) {
                        ForEach(model.customIcons) { icon in
                            if let image = NSImage(data: icon.data) {
                                cell(.custom(uuid: icon.id)) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(width: 28, height: 28)
                                }.accessibilityIdentifier("entry-icon-picker.custom.\(icon.id.uuidString)")
                                    .accessibilityLabel(icon.name.isEmpty ? String(localized: "Custom icon") : icon.name)
                            }
                        }
                    }
                }
                Text("Standard Icons").font(.headline)
                LazyVGrid(columns: columns) {
                    ForEach(model.standardIconIDs, id: \.self) { id in
                        cell(.standard(iconID: id)) { StandardIconView(iconID: id).font(.title2) }
                            .accessibilityIdentifier("entry-icon-picker.standard.\(id)")
                    }
                }
                Text("The grid scrolls through all the standard KeePass icons.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.isDownloading { ProgressView() }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }.padding(4)
        }
        .disabled(model.isDownloading)
        .sheet(isPresented: $isManaging, onDismiss: {
            if let database {
                model.refreshCustomIcons(database.customIcons.filter { NSImage(data: $0.data) != nil })
            }
        }) {
            if let database { NavigationStack { CustomIconsView(viewModel: database) } }
        }
    }
    @State private var isManaging = false
    private let columns = [GridItem(.adaptive(minimum: 40), spacing: 12)]
    private func cell<Content: View>(_ selection: EntryIconSelection, @ViewBuilder content: () -> Content) -> some View {
        Button { model.selection = selection } label: {
            content().frame(width: 40, height: 40)
                .background(model.selection == selection ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(model.selection == selection ? Color.accentColor : Color.clear))
        }.buttonStyle(.plain)
        .accessibilityAddTraits(model.selection == selection ? [.isSelected] : [])
    }
}
