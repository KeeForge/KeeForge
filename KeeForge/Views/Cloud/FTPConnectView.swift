import SwiftUI

/// Manual connect form for FTP servers, presented in place of a hosted OAuth
/// flow. On success the created `CloudAccount` is handed back through
/// `onConnected`.
struct FTPConnectView: View {
    @State private var viewModel: FTPConnectViewModel
    let onConnected: (CloudAccount) -> Void
    let onCancel: () -> Void

    @State private var isPasswordVisible = false

    init(
        connector: any FTPConnecting,
        onConnected: @escaping (CloudAccount) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: FTPConnectViewModel(connector: connector))
        self.onConnected = onConnected
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Server",
                        text: $viewModel.serverURL,
                        prompt: Text(verbatim: "ftp://nas.local/vaults")
                            .foregroundColor(Color(.placeholderText))
                    )
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        // The section header already captions this field.
                        .macLabelsHidden()
                        .macFormFieldStyle()
                        .accessibilityIdentifier("ftp.connect.server-field")
                } header: {
                    Text("Server")
                } footer: {
                    Text("The path starts in the folder your FTP account opens in.")
                }

                Section {
                    TextField("Username", text: $viewModel.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .macFormFieldStyle()
                        .accessibilityIdentifier("ftp.connect.username-field")

                    PasswordInputRow(
                        title: String(localized: "Password"),
                        text: $viewModel.password,
                        isVisible: $isPasswordVisible,
                        fieldAccessibilityIdentifier: "ftp.connect.password-field",
                        visibilityAccessibilityIdentifier: "ftp.connect.password-visibility-button"
                    )
                    .macFormFieldStyle()
                } header: {
                    Text("Account")
                }

                Section {
                    Toggle("Allow Unencrypted FTP", isOn: $viewModel.allowsUnencryptedFTP)
                        .accessibilityIdentifier("ftp.connect.allow-unencrypted-toggle")
                } header: {
                    Text("Security")
                } footer: {
                    Text("FTP sends your username, password, and database file without encryption. Only use it on a local network you trust.")
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Label {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                        .accessibilityIdentifier("ftp.connect.error")
                    }
                }
            }
            .macGroupedForm()
            .navigationTitle("Connect FTP")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(viewModel.isConnecting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .accessibilityIdentifier("ftp.connect.cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isConnecting {
                        ProgressView()
                    } else {
                        Button("Connect") {
                            connect()
                        }
                        .accessibilityIdentifier("ftp.connect.submit")
                    }
                }
            }
        }
        .macSheetFrame(minWidth: 480, minHeight: 380)
    }

    private func connect() {
        Task {
            if let account = await viewModel.connect() {
                onConnected(account)
            }
        }
    }
}
