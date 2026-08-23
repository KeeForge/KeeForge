import SwiftUI

/// Manual connect form for WebDAV servers (Nextcloud, Synology, Apache mod_dav,
/// etc.). Presented in place of a hosted OAuth flow. On success the created
/// `CloudAccount` is handed back through `onConnected`.
struct WebDAVConnectView: View {
    @State private var viewModel: WebDAVConnectViewModel
    let onConnected: (CloudAccount) -> Void
    let onCancel: () -> Void

    @State private var isPasswordVisible = false

    init(
        connector: any WebDAVConnecting,
        onConnected: @escaping (CloudAccount) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: WebDAVConnectViewModel(connector: connector))
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
                        prompt: Text(verbatim: "https://cloud.example.com/…")
                            .foregroundColor(Color(.placeholderText))
                    )
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        // The section header already captions this field.
                        .macLabelsHidden()
                        .macFormFieldStyle()
                        .accessibilityIdentifier("webdav.connect.server-field")
                } header: {
                    Text("Server")
                } footer: {
                    Text("Example: https://cloud.example.com/remote.php/dav/files/USERNAME/ — for Nextcloud, use an app password")
                }

                Section {
                    TextField("Username", text: $viewModel.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .macFormFieldStyle()
                        .accessibilityIdentifier("webdav.connect.username-field")

                    PasswordInputRow(
                        title: String(localized: "Password"),
                        text: $viewModel.password,
                        isVisible: $isPasswordVisible,
                        fieldAccessibilityIdentifier: "webdav.connect.password-field",
                        visibilityAccessibilityIdentifier: "webdav.connect.password-visibility-button"
                    )
                    .macFormFieldStyle()
                } header: {
                    Text("Account")
                }

                Section {
                    Toggle("Allow Unencrypted HTTP", isOn: $viewModel.allowsUnencryptedHTTP)
                        .accessibilityIdentifier("webdav.connect.allow-http-toggle")
                } header: {
                    Text("Advanced")
                } footer: {
                    if viewModel.allowsUnencryptedHTTP {
                        Text("HTTP sends your WebDAV username, password, and database traffic without encryption. Only use it on a local network you trust.")
                    } else {
                        Text("Keep this off unless your trusted local WebDAV server cannot use HTTPS.")
                    }
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
                        .accessibilityIdentifier("webdav.connect.error")
                    }
                }
            }
            .macGroupedForm()
            .navigationTitle("Connect WebDAV")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(viewModel.isConnecting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .accessibilityIdentifier("webdav.connect.cancel")
                }

                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isConnecting {
                        ProgressView()
                    } else {
                        Button("Connect") {
                            connect()
                        }
                        .accessibilityIdentifier("webdav.connect.submit")
                    }
                }
            }
        }
    }

    private func connect() {
        Task {
            if let account = await viewModel.connect() {
                onConnected(account)
            }
        }
    }
}
