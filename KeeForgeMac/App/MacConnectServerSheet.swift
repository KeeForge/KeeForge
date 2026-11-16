import AppKit
import SwiftUI

/// The New Database and Connect to Server boards: a 140 pt label column and a 330 pt control column.
enum MacSheetFormMetrics {
    static let width: CGFloat = 480
    /// A sheet on the shared `MacSettingsForm` grid: its 170 pt label column plus a 320 pt control column.
    static let gridWidth: CGFloat = 500
    static let rowSpacing: CGFloat = 12
}

struct MacConnectServerSheet: View {
    @Bindable var model: MacConnectServerModel
    var showsTypePicker = true
    @State private var passwordVisible = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if showsTypePicker {
                    Picker("Connect to Server", selection: $model.serverType) {
                        ForEach(MacConnectServerModel.serverTypes) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    .accessibilityIdentifier("connect-server.type")
                }
                if model.serverType == .webDAV { webDAVForm } else { ftpForm }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                        .accessibilityIdentifier(model.serverType == .webDAV ? "webdav.connect.error" : "ftp.connect.error")
                }
            }
            .padding(.vertical, 4)
        }
        .disabled(model.isConnecting)
    }

    private var webDAVForm: some View {
        @Bindable var form = model.webDAV
        return Form {
            TextField("Server:", text: $form.serverURL)
                .accessibilityIdentifier("webdav.connect.server-field")
            caption("Example: https://cloud.example.com/remote.php/dav/files/USERNAME/ — for Nextcloud, use an app password")
            Divider()
            TextField("Username:", text: $form.username)
                .frame(width: 220)
                .accessibilityIdentifier("webdav.connect.username-field")
            LabeledContent("Password:") { PasswordInputRow(title: String(localized: "Password"), text: $form.password, isVisible: $passwordVisible,
                             fieldAccessibilityIdentifier: "webdav.connect.password-field",
                             visibilityAccessibilityIdentifier: "webdav.connect.password-visibility-button", usesPasswordAutoFill: false).labelsHidden() }
            Divider()
            LabeledContent("Advanced:") {
                Toggle("Allow Unencrypted HTTP", isOn: $form.allowsUnencryptedHTTP)
                    .accessibilityIdentifier("webdav.connect.allow-http-toggle")
            }
            if form.allowsUnencryptedHTTP {
                caption("HTTP sends your username, password and database unencrypted, so use it only on a local network you trust.")
            } else {
                caption("Keep this off unless your trusted local WebDAV server cannot use HTTPS.")
            }
        }.formStyle(.columns).frame(width: MacSheetFormMetrics.width)
    }
    private var ftpForm: some View {
        @Bindable var form = model.ftp
        return Form {
            TextField("Server:", text: $form.serverURL)
                .accessibilityIdentifier("ftp.connect.server-field")
            caption("The path starts in the folder your FTP account opens in.")
            Divider()
            TextField("Username:", text: $form.username)
                .frame(width: 220)
                .accessibilityIdentifier("ftp.connect.username-field")
            LabeledContent("Password:") { PasswordInputRow(title: String(localized: "Password"), text: $form.password, isVisible: $passwordVisible,
                             fieldAccessibilityIdentifier: "ftp.connect.password-field",
                             visibilityAccessibilityIdentifier: "ftp.connect.password-visibility-button", usesPasswordAutoFill: false).labelsHidden() }
            Divider()
            LabeledContent("Security:") {
                Toggle("Allow Unencrypted FTP", isOn: $form.allowsUnencryptedFTP)
                    .accessibilityIdentifier("ftp.connect.allow-unencrypted-toggle")
            }
            if model.showsFTPWarnings {
                caption("FTP sends your username, password and database unencrypted, so use it only on a local network you trust.")
                    .foregroundStyle(.orange)
                caption("Avoid editing this database elsewhere at the same time: FTP can’t stop a concurrent change from being overwritten.")
            }
        }.formStyle(.columns).frame(width: MacSheetFormMetrics.width)
    }
    private func caption(_ key: LocalizedStringKey) -> some View {
        LabeledContent("") { settingsCaption(key) }
    }
}
