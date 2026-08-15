import Foundation

enum WhatsNewPlatform: Hashable, Sendable {
    case iOS
    case macOS

    static var current: WhatsNewPlatform {
        #if os(macOS)
        .macOS
        #else
        .iOS
        #endif
    }
}

struct WhatsNewFeature: Identifiable, Sendable {
    let id: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let systemImage: String
    let platforms: Set<WhatsNewPlatform>

    init(
        id: String,
        title: LocalizedStringResource,
        detail: LocalizedStringResource,
        systemImage: String,
        platforms: Set<WhatsNewPlatform> = [.iOS, .macOS]
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.platforms = platforms
    }
}

struct WhatsNewRelease: Identifiable, Sendable {
    let version: String
    let features: [WhatsNewFeature]

    var id: String { version }
}

/// Curated, user-facing release notes shown by `WhatsNewView`.
///
/// Before each release that adds features, add a case matching the target's
/// `MARKETING_VERSION`. Use only the changelog's New Features section as input,
/// then rewrite those bullets as short, benefit-led copy. Bug fixes and
/// internal changes do not belong in this catalog.
enum WhatsNewCatalog {
    static func release(version: String, platform: WhatsNewPlatform) -> WhatsNewRelease? {
        let features: [WhatsNewFeature]

        switch version {
        case "1.14.0":
            features = [
                WhatsNewFeature(
                    id: "change-master-key",
                    title: "Change your master password",
                    detail: "Set a new master password, or add, replace, or remove a key file, right from Database Details. A backup under the old key is kept, and Face ID or Touch ID keeps working.",
                    systemImage: "lock.rotation"
                ),
                WhatsNewFeature(
                    id: "totp-enrollment",
                    title: "Set up verification codes",
                    detail: "Scan a QR code, paste a setup link, or type a key to add a verification code while editing an entry. Codes are saved in your database, so they work in other KeePass apps too.",
                    systemImage: "qrcode.viewfinder"
                ),
                WhatsNewFeature(
                    id: "chinese-localization",
                    title: "Use KeeForge in Chinese",
                    detail: "KeeForge is now fully translated into Simplified and Traditional Chinese throughout the app and AutoFill.",
                    systemImage: "globe"
                ),
            ]
        case "1.13.1":
            features = [
                WhatsNewFeature(
                    id: "export-copy",
                    title: "Export a copy of your database",
                    detail: "Long-press a database — or open Database Details — and choose Export Copy… to save it to Files under a timestamped name. Handy for merging changes with another KeePass app when a cloud upload is stuck.",
                    systemImage: "square.and.arrow.up"
                ),
                WhatsNewFeature(
                    id: "device-backups",
                    title: "Reach your on-device backups",
                    detail: "Database Details now lists the last five backups KeeForge made on this device before saving or replacing a database, and each one can be exported to Files.",
                    systemImage: "clock.arrow.circlepath"
                ),
            ]
        case "1.13.0":
            features = [
                WhatsNewFeature(
                    id: "file-sharing",
                    title: "Copy databases from your computer",
                    detail: "KeeForge's Documents folder now appears in Finder and Windows File Sharing. Drop a .kdbx file there and it joins your database list automatically.",
                    systemImage: "folder.badge.plus",
                    platforms: [.iOS]
                ),
                WhatsNewFeature(
                    id: "entry-icons",
                    title: "Give your entries their own icons",
                    detail: "Tap an entry's icon to pick from the KeePass icon set or your database's custom icons — or download the website's own icon. Your choice is saved in the database, so it shows up everywhere. Thanks to @miquno.",
                    systemImage: "paintpalette"
                ),
                WhatsNewFeature(
                    id: "autofill-create-credential",
                    title: "Create credentials right from AutoFill",
                    detail: "Signing up somewhere new? The AutoFill picker's + button starts a new entry pre-filled with the site and a generated password, and fills it as soon as you save. Thanks to @miquno.",
                    systemImage: "person.badge.plus",
                    platforms: [.iOS]
                ),
            ]
        case "1.12.0":
            features = [
                WhatsNewFeature(
                    id: "group-editor",
                    title: "Edit groups in one place",
                    detail: "Rename a group, organize it with tags, choose an icon, add notes, and control whether its entries appear in Search and AutoFill.",
                    systemImage: "square.and.pencil"
                ),
                WhatsNewFeature(
                    id: "passkey-registration",
                    title: "Save new passkeys with KeeForge",
                    detail: "Choose KeeForge when an app or website offers to add a passkey, and save it directly to your default AutoFill database.",
                    systemImage: "person.badge.key",
                    platforms: [.iOS]
                ),
                WhatsNewFeature(
                    id: "entry-folder-context",
                    title: "See where every entry belongs",
                    detail: "Search results and the tag browser now show the folder each entry lives in, so similarly named entries are easier to tell apart.",
                    systemImage: "folder"
                ),
                WhatsNewFeature(
                    id: "french-spanish-localization",
                    title: "Use KeeForge in French or Spanish",
                    detail: "KeeForge is now fully translated into French and Spanish throughout the app and AutoFill.",
                    systemImage: "globe"
                ),
            ]
        case "1.11.0":
            features = [
                WhatsNewFeature(
                    id: "entry-history",
                    title: "See and restore earlier versions",
                    detail: "Browse the earlier versions of an entry and restore one. The current contents are kept, so you can undo it. Thanks to @miquno.",
                    systemImage: "clock.arrow.circlepath"
                ),
                WhatsNewFeature(
                    id: "tag-browser",
                    title: "Browse your entries by tag",
                    detail: "Find entries by the tags you already use, including tags inherited from their group. Search by tag, and pick from suggestions while editing.",
                    systemImage: "tag"
                ),
                WhatsNewFeature(
                    id: "autofill-possible-matches",
                    title: "Clearer AutoFill suggestions",
                    detail: "Exact matches for a site are listed apart from possible matches on related subdomains. A possible match is never filled unless you pick it. Thanks to @ftorga.",
                    systemImage: "checkmark.shield"
                ),
                WhatsNewFeature(
                    id: "group-icons",
                    title: "Give your groups their own icons",
                    detail: "Choose from the standard KeePass icon set so your groups are recognizable at a glance. Thanks to @miquno.",
                    systemImage: "paintpalette"
                ),
            ]
        case "1.10.4":
            features = [
                WhatsNewFeature(
                    id: "autofill-all-databases",
                    title: "AutoFill from all your databases",
                    detail: "Get suggestions from every database at once, choose which ones AutoFill uses, and switch databases without leaving the AutoFill panel.",
                    systemImage: "rectangle.stack"
                ),
                WhatsNewFeature(
                    id: "autofill-hidden-groups",
                    title: "Hide groups from AutoFill",
                    detail: "Hide a group and its entries stop appearing when you fill passwords, while staying fully visible when you browse the database in the app.",
                    systemImage: "eye.slash"
                ),
                WhatsNewFeature(
                    id: "community-contributors",
                    title: "Built with the community",
                    detail: "Thanks to @miquno and @ftorga, whose open-source contributions helped shape this release.",
                    systemImage: "heart"
                ),
            ]
        case "1.10.3":
            features = [
                WhatsNewFeature(
                    id: "database-file-details",
                    title: "View database details",
                    detail: "See your database's format, file size, last update, encryption, key-derivation settings, and compression without unlocking it.",
                    systemImage: "doc.text"
                ),
                WhatsNewFeature(
                    id: "reliability-improvements",
                    title: "A more reliable KeeForge",
                    detail: "This update includes a broad set of fixes and refinements across unlocking, search, AutoFill, cloud sync, WebDAV, passkeys, one-time codes, and more.",
                    systemImage: "checkmark.circle",
                    platforms: [.iOS]
                ),
            ]
        case "1.10.2":
            features = [
                WhatsNewFeature(
                    id: "feedback-options",
                    title: "Send richer feedback",
                    detail: "Attach a photo when it helps explain an issue, and optionally add an email address if you'd like a reply.",
                    systemImage: "photo"
                ),
                WhatsNewFeature(
                    id: "german-localization",
                    title: "Use KeeForge in German",
                    detail: "KeeForge is now fully translated into German throughout the app and AutoFill.",
                    systemImage: "globe"
                ),
                WhatsNewFeature(
                    id: "keeotp-codes",
                    title: "Use KeeOTP verification codes",
                    detail: "KeeForge now recognizes one-time passwords saved by the KeeOTP and KeeOtp2 plugins, so you can use their verification codes normally.",
                    systemImage: "timer"
                ),
            ]
        case "1.10.1":
            features = [
                WhatsNewFeature(
                    id: "database-compatibility",
                    title: "Open more KeePass databases",
                    detail: "KeeForge can now open older KeePass 3.1 vaults and databases protected with Twofish — and keeps their original encryption when you save.",
                    systemImage: "lock.doc"
                ),
                WhatsNewFeature(
                    id: "local-webdav",
                    title: "Connect to local WebDAV servers",
                    detail: "Use KeeForge with a trusted local WebDAV server even when it doesn't support HTTPS. The option lives under Advanced and includes a clear security warning.",
                    systemImage: "network"
                ),
                WhatsNewFeature(
                    id: "autofill-setup",
                    title: "Set up AutoFill more easily",
                    detail: "If AutoFill is off, KeeForge now lets you know and helps you turn it on right from your database list or Settings.",
                    systemImage: "text.cursor",
                    platforms: [.iOS]
                ),
            ]
        default:
            return nil
        }

        let supportedFeatures = features.filter { $0.platforms.contains(platform) }
        guard supportedFeatures.isEmpty == false else { return nil }

        return WhatsNewRelease(version: version, features: supportedFeatures)
    }
}

@MainActor
struct WhatsNewPresentationHistory {
    private static let presentedVersionsKey = "KeeForge.whatsNew.presentedVersions"

    let defaults: UserDefaults

    func claimPresentation(for version: String) -> Bool {
        var presentedVersions = Set(
            defaults.stringArray(forKey: Self.presentedVersionsKey) ?? []
        )
        guard presentedVersions.insert(version).inserted else {
            return false
        }

        defaults.set(presentedVersions.sorted(), forKey: Self.presentedVersionsKey)
        return true
    }
}

@MainActor
enum WhatsNewPresentationService {

    /// Returns and claims the current release, ensuring it is presented at
    /// most once on this device. A version with no feature catalog is skipped.
    static func releaseToPresent(
        currentVersion: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
        platform: WhatsNewPlatform = .current,
        defaults: UserDefaults = .standard,
        uiTestingPresentationOverride: Bool? = uiTestingPresentationOverride
    ) -> WhatsNewRelease? {
        if uiTestingPresentationOverride == false {
            return nil
        }

        guard let currentVersion,
              let release = WhatsNewCatalog.release(
                  version: currentVersion,
                  platform: platform
              ) else {
            return nil
        }

        // Opted-in UI tests need deterministic presentation even when the
        // simulator's defaults survived a previous test run.
        if uiTestingPresentationOverride == true {
            return release
        }

        let history = WhatsNewPresentationHistory(defaults: defaults)
        guard history.claimPresentation(for: currentVersion) else {
            return nil
        }
        return release
    }

    private static var uiTestingPresentationOverride: Bool? {
        let processInfo = ProcessInfo.processInfo
        guard processInfo.arguments.contains("-ui-testing") else { return nil }
        return processInfo.environment["UI_TEST_SHOW_WHATS_NEW"] == "1"
    }
}
