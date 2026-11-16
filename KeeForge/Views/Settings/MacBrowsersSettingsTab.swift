#if os(macOS)
import SwiftUI

/// Settings ▸ Browsers: the opt-in bridge, setting it up in each browser on
/// this Mac, and the browsers paired with it.
struct MacBrowsersSettingsTab: View {
    @Bindable var model: MacBrowserBridgeSettingsModel
    /// Each asks for confirmation in an AppKit alert before calling the model.
    let remove: (MacBrowserBridgeSettingsModel.PairedRow) -> Void
    let removeAll: () -> Void

    var body: some View {
        MacSettingsForm {
            MacSettingsRow("Browser extensions:") {
                Toggle("Allow browser extensions to fill from KeeForge", isOn: $model.isEnabled)
                    .accessibilityIdentifier("settings.browsers.toggle")
                if let message = model.unavailabilityMessage {
                    Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                settingsCaption("When on, a paired browser can see which logins match a site and fill one after you confirm, while a database is unlocked.", indented: true)
            }
            MacSettingsSeparator()
            MacSettingsRow("Set up a browser:") {
                GroupBox { hostRows.padding(4).frame(maxWidth: .infinity, alignment: .leading) }
                    .accessibilityIdentifier("settings.browsers.host-list")
                settingsCaption("After setting up a browser, install the KeeForge extension in it and choose Pair.")
            }
            MacSettingsSeparator()
            MacSettingsRow("Paired browsers:") {
                GroupBox { pairedRows.padding(4).frame(maxWidth: .infinity, alignment: .leading) }
                    .accessibilityIdentifier("settings.browsers.paired-list")
                if model.removalFailed {
                    Text("KeeForge couldn’t remove the pairing. Try again.")
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if !model.pairedRows.isEmpty {
                    Button("Remove All…") { removeAll() }
                        .accessibilityIdentifier("settings.browsers.remove-all")
                }
            }
        }
        .onAppear { model.refreshHosts() }
    }

    @ViewBuilder
    private var hostRows: some View {
        if model.hostRows.isEmpty {
            Text("None of the browsers KeeForge supports is installed on this Mac.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.hostRows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: row.name)
                                Text(status(of: row.state)).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            buttons(for: row)
                        }
                        if let error = model.errorMessage(for: row.browser) {
                            Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func buttons(for row: MacBrowserBridgeSettingsModel.HostRow) -> some View {
        let id = "settings.browsers.host.\(row.browser.rawValue)"
        HStack {
            switch row.state {
            case .notSetUp:
                Button("Set Up…") { Task { await model.setUp(row.browser) } }
                    .accessibilityIdentifier("\(id).set-up")
            case .ready:
                Button("Remove") { model.removeHost(row.browser) }
                    .accessibilityIdentifier("\(id).remove")
            case .needsRepair:
                Button("Repair") { model.repair(row.browser) }
                    .accessibilityIdentifier("\(id).repair")
                Button("Remove") { model.removeHost(row.browser) }
                    .accessibilityIdentifier("\(id).remove")
            case .accessLost:
                Button("Set Up Again…") { Task { await model.setUp(row.browser) } }
                    .accessibilityIdentifier("\(id).set-up")
            case .extensionIDNotConfigured, .notInstalled:
                EmptyView()
            }
        }
        .disabled(model.busyBrowser != nil)
    }

    private func status(of state: BrowserHostInstallerState) -> LocalizedStringKey {
        switch state {
        case .ready: "Ready"
        case .needsRepair: "Needs repair"
        case .accessLost: "KeeForge can no longer reach this browser’s folder"
        case .extensionIDNotConfigured: "This version of KeeForge can’t set up this browser yet."
        case .notSetUp, .notInstalled: "Not set up"
        }
    }

    @ViewBuilder
    private var pairedRows: some View {
        let rows = model.pairedRows
        if rows.isEmpty {
            Text("No paired browsers").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: row.name)
                            Text("Paired \(row.pairedDate) · \(row.lastUsed)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove…") { remove(row) }
                            .accessibilityIdentifier("settings.browsers.paired.\(row.id).remove")
                    }
                }
            }
        }
    }
}
#endif
