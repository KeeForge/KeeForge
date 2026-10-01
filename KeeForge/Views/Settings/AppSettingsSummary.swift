import Foundation

/// The one-line state each row of the iOS Settings root shows under its title.
enum AppSettingsSummary {
    static func security(
        autoUnlockBiometric: BiometricService.BiometricType,
        autoLockTimeout: SettingsService.AutoLockTimeout,
        lockOnBackground: Bool
    ) -> String {
        let biometric: String? = switch autoUnlockBiometric {
        case .faceID: String(localized: "Face ID")
        case .touchID: String(localized: "Touch ID")
        case .none: nil
        }

        let lock = switch autoLockTimeout {
        case .immediately:
            String(localized: "Locks immediately")
        case .never:
            lockOnBackground ? String(localized: "Locks in background") : String(localized: "No auto-lock")
        case .thirtySeconds, .oneMinute, .fiveMinutes:
            String(localized: "Locks after \(autoLockTimeout.title)")
        }

        return SettingsSummaryText.joined([biometric, lock])
    }

    /// `isProviderEnabled` is nil until the system has reported it, and the
    /// row then says nothing about it rather than guessing.
    static func autoFill(isProviderEnabled: Bool?, databases: [DatabaseReference]) -> String {
        let provider = isProviderEnabled.map { $0 ? String(localized: "On") : String(localized: "Off") }
        let selection: String? = if databases.isEmpty {
            nil
        } else {
            String(localized: "Databases: \(databases.count(where: \.autoFillEnabled)) of \(databases.count)")
        }
        return SettingsSummaryText.joined([provider, selection])
    }

    static func display(appearanceMode: SettingsService.AppearanceMode, showWebsiteIcons: Bool) -> String {
        SettingsSummaryText.joined([
            appearanceMode.title,
            showWebsiteIcons ? String(localized: "Favicons on") : String(localized: "Favicons off"),
        ])
    }

    static func cloudAccounts(_ accounts: [CloudAccount]) -> String {
        var providerNames: [String] = []
        for account in accounts {
            let name = account.providerKind?.displayName ?? account.provider.capitalized
            if providerNames.contains(name) == false {
                providerNames.append(name)
            }
        }
        guard providerNames.isEmpty == false else { return String(localized: "None") }
        return providerNames.formatted(.list(type: .and, width: .narrow))
    }
}
