import SwiftUI

struct FeedbackComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: FeedbackComposerModel

    init(context: FeedbackComposerContext) {
        _model = State(initialValue: FeedbackComposerModel(context: context))
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Group {
                if model.didSubmit {
                    successState
                } else {
                    Form {
                        Section("Message") {
                            Text(model.context.prompt)
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            TextEditor(text: $model.message)
                                .frame(minHeight: 150)
                                .accessibilityIdentifier("feedback.message")
                        }

                        if model.context.hasErrorContext {
                            Section("Attached Error Details") {
                                LabeledContent("Category", value: model.context.errorCategory)
                                LabeledContent("Code", value: model.context.errorCode)

                                Text(model.context.details)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }

                        Section("Follow-Up") {
                            Toggle("I'm okay with a follow-up", isOn: $model.consentToContact)

                            if model.consentToContact {
                                TextField("Email or other contact", text: $model.contact)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }

                        Section("Privacy") {
                            Text("KeeForge includes app version, build number, iOS version, device model, and the safe details shown above.")
                            Text("KeeForge does not include database contents, passwords, key files, raw vault files, or unsanitized logs.")
                        }
                    }
                }
            }
            .navigationTitle(model.context.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.didSubmit ? "Done" : "Cancel") {
                        dismiss()
                    }
                }

                if model.didSubmit == false {
                    ToolbarItem(placement: .confirmationAction) {
                        if model.isSubmitting {
                            ProgressView()
                        } else {
                            Button("Send") {
                                Task {
                                    await model.submit()
                                }
                            }
                            .disabled(model.canSend == false)
                        }
                    }
                }
            }
            .alert(
                "Couldn't Send Feedback",
                isPresented: Binding(
                    get: { model.submissionErrorMessage != nil },
                    set: { isPresented in
                        if isPresented == false {
                            model.submissionErrorMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.submissionErrorMessage ?? "")
            }
        }
    }

    private var successState: some View {
        ContentUnavailableView(
            "Feedback Sent",
            systemImage: "paperplane.circle.fill",
            description: Text("Thanks for helping improve KeeForge.")
        )
        .padding()
    }
}
