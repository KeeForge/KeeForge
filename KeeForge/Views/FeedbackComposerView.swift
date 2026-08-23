import PhotosUI
import SwiftUI

struct FeedbackComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: FeedbackComposerModel
    @State private var selectedPhotoItem: PhotosPickerItem?

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

                        followUpSection
                        photoSection

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

                        Section("Privacy") {
                            Text("No GitHub or email required. KeeForge only sends the message you type, plus visible attached error details, the follow-up email if you enable follow-up, and the photo if you attach one. Database-open reports may include visible app/device metadata, cloud sync status, and short file hash prefixes, but never database contents, passwords, key files, or raw vault files.")
                        }
                    }
                    .macGroupedForm()
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
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let rawData = try? await newItem.loadTransferable(type: Data.self) {
                        await model.attachPhoto(rawData: rawData)
                    } else {
                        model.photoErrorMessage = FeedbackSubmissionError.photoUnreadable.localizedDescription
                    }
                    selectedPhotoItem = nil
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
            .alert(
                "Couldn't Attach Photo",
                isPresented: Binding(
                    get: { model.photoErrorMessage != nil },
                    set: { isPresented in
                        if isPresented == false {
                            model.photoErrorMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.photoErrorMessage ?? "")
            }
        }
    }

    private var followUpSection: some View {
        @Bindable var model = model

        return Section {
            Toggle("Allow Follow-Up", isOn: $model.allowFollowUp)
                .accessibilityIdentifier("feedback.allow-follow-up")

            if model.allowFollowUp {
                TextField("Email", text: $model.contactEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .macFormFieldStyle()
                    .accessibilityIdentifier("feedback.contact-email")
            }
        } header: {
            Text("Follow-Up")
        } footer: {
            if model.allowFollowUp {
                Text("Your email is used only to reply about this feedback.")
            }
        }
    }

    private var photoSection: some View {
        Section {
            if let photo = model.attachedPhoto {
                HStack(spacing: 12) {
                    if let platformImage = PlatformImage(data: photo.data) {
                        Image(platformImage: platformImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading) {
                        Text("Attached Photo")
                        Text(Int64(photo.data.count).formatted(.byteCount(style: .file)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Remove Photo", role: .destructive) {
                    model.removePhoto()
                }
                .accessibilityIdentifier("feedback.remove-photo")
            } else if model.isProcessingPhoto {
                ProgressView()
            } else {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("Attach Photo", systemImage: "photo")
                }
                .accessibilityIdentifier("feedback.attach-photo")
            }
        } header: {
            Text("Photo")
        } footer: {
            Text("Optional. One photo, resized and sent as a JPEG. Photo metadata such as location is removed.")
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
