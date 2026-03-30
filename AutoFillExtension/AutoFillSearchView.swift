import SwiftUI

struct AutoFillSearchView: View {
    let entries: [KPEntry]
    let onSelect: (KPEntry) -> Void
    let onCancel: () -> Void
    let initialSearchText: String

    @State private var searchText: String

    init(entries: [KPEntry], initialSearchText: String = "", onSelect: @escaping (KPEntry) -> Void, onCancel: @escaping () -> Void) {
        self.entries = entries
        self.initialSearchText = initialSearchText
        self.onSelect = onSelect
        self.onCancel = onCancel
        self._searchText = State(initialValue: initialSearchText)
    }

    private var filteredEntries: [KPEntry] {
        guard !searchText.isEmpty else { return entries }
        let query = searchText.lowercased()
        return entries.filter { entry in
            entry.title.lowercased().contains(query) ||
            entry.username.lowercased().contains(query) ||
            entry.url.lowercased().contains(query) ||
            entry.notes.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredEntries) { entry in
                Button {
                    onSelect(entry)
                } label: {
                    HStack {
                        Image(systemName: entry.systemIconName)
                            .foregroundStyle(.tint)
                            .font(.system(size: 16))
                            .frame(width: 28)

                        VStack(alignment: .leading) {
                            Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                                .font(.body)
                                .foregroundStyle(.primary)
                            if !entry.username.isEmpty {
                                Text(entry.username)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search entries")
            .navigationTitle("Choose Credential")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
    }
}
