import SwiftUI

struct EntryCustomFieldOrderSheet: ViewModifier {
    @Binding var isPresented: Bool
    @Bindable var form: EntryEditViewModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            NavigationStack {
                List {
                    ForEach(Array(form.customFields.enumerated()), id: \.element.id) { index, field in
                        HStack {
                            Text(field.key.isEmpty ? String(localized: "Field Name") : field.key)
                                .accessibilityIdentifier("entry-edit.custom-field.order.\(index)")
                            #if os(macOS)
                            Spacer()
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            #endif
                        }
                    }
                    .onMove(perform: form.moveCustomFields)
                }
                #if os(iOS)
                // System reorder handles drag at once and offer VoiceOver move actions.
                .environment(\.editMode, .constant(.active))
                #endif
                .navigationTitle("Reorder Fields")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isPresented = false }
                            .accessibilityIdentifier("entry-edit.custom-field.order.done")
                    }
                }
            }
            .frame(minWidth: 300, minHeight: 300)
        }
    }
}
