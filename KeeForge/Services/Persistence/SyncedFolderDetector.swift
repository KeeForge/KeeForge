import FileProvider
import Foundation

enum SyncedFolderLocation: Sendable, Equatable {
    case iCloudDrive
    case dropbox
    case googleDrive
    case oneDrive
    case box
    case unknownThirdParty(domainIdentifier: String)
    case notSynced

    var providerDisplayName: String? {
        switch self {
        case .iCloudDrive:
            "iCloud Drive"
        case .dropbox:
            "Dropbox"
        case .googleDrive:
            "Google Drive"
        case .oneDrive:
            "OneDrive"
        case .box:
            "Box"
        case .unknownThirdParty, .notSynced:
            nil
        }
    }
}

enum SyncedFolderWarningAction: Sendable, Equatable {
    case continueEditing
    case keepReadOnly
}

enum AcknowledgmentResult: Sendable, Equatable {
    case acknowledged
    case keptReadOnly
}

struct SyncedFolderWarning: Sendable, Equatable {
    let location: SyncedFolderLocation

    var title: String {
        switch location {
        case .iCloudDrive:
            "This database file is in iCloud Drive."
        case .dropbox:
            "This database file is stored in Dropbox."
        case .googleDrive:
            "This database file is stored in Google Drive."
        case .oneDrive:
            "This database file is stored in OneDrive."
        case .box:
            "This database file is stored in Box."
        case .unknownThirdParty:
            "This database file may be synced by another app on this device."
        case .notSynced:
            ""
        }
    }

    var message: String {
        switch location {
        case .iCloudDrive:
            return "iCloud may sync changes from another device while you're editing. We recommend keeping all writes on one device."
        case .dropbox, .googleDrive, .oneDrive, .box:
            let providerName = location.providerDisplayName ?? "another app"
            return "The \(providerName) app on this device — and on any other device signed into the same account — could overwrite your changes if you both edit the database at the same time. Continue editing only if you keep all writes confined to one device at a time."
        case .unknownThirdParty:
            return "Concurrent edits from another device or app could overwrite your changes."
        case .notSynced:
            return ""
        }
    }

    var continueButtonTitle: String {
        "Continue editing"
    }

    var keepReadOnlyButtonTitle: String {
        "Keep read-only"
    }
}

enum SyncedFolderDetector {
    struct ResolvedLocation: Sendable {
        let url: URL
        let usesSecurityScope: Bool
    }

    struct Environment: Sendable {
        var resolveLocation: @Sendable (DatabaseReference) -> ResolvedLocation?
        var isUbiquitousItem: @Sendable (URL) -> Bool
        var providerIdentifier: @Sendable (URL) async -> String?

        static let live = Environment(
            resolveLocation: { reference in
                SyncedFolderDetector.resolveLocation(for: reference)
            },
            isUbiquitousItem: { url in
                (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
            },
            providerIdentifier: { url in
                await SyncedFolderDetector.providerIdentifier(for: url)
            }
        )
    }

    static func detect(reference: DatabaseReference) async -> SyncedFolderLocation {
        await detect(reference: reference, environment: .live)
    }

    static func detect(
        reference: DatabaseReference,
        environment: Environment
    ) async -> SyncedFolderLocation {
        guard case .local = reference.source else {
            return .notSynced
        }

        guard reference.bookmarkData != nil else {
            return .notSynced
        }

        guard let resolvedLocation = environment.resolveLocation(reference) else {
            return .notSynced
        }

        let hasSecurityScope = resolvedLocation.usesSecurityScope
            ? resolvedLocation.url.startAccessingSecurityScopedResource()
            : false
        defer {
            if hasSecurityScope {
                resolvedLocation.url.stopAccessingSecurityScopedResource()
            }
        }

        if environment.isUbiquitousItem(resolvedLocation.url) {
            return .iCloudDrive
        }

        guard let providerIdentifier = await environment.providerIdentifier(resolvedLocation.url) else {
            return .notSynced
        }

        return Self.location(for: providerIdentifier)
    }

    private static func resolveLocation(for reference: DatabaseReference) -> ResolvedLocation? {
        guard let url = DatabaseListStore.resolveDatabaseURL(for: reference) else {
            return nil
        }

        return ResolvedLocation(url: url, usesSecurityScope: true)
    }

    private static func location(for providerIdentifier: String) -> SyncedFolderLocation {
        switch providerIdentifier {
        // Known File Provider bundle identifiers as of Slice 04 implementation.
        case "com.dropbox.Dropbox.FileProvider":
            .dropbox
        case "com.google.Drive.FileProviderExtension":
            .googleDrive
        case "com.microsoft.skydrive.OneDriveFileProvider":
            .oneDrive
        case "com.box.BoxFileProvider":
            .box
        default:
            .unknownThirdParty(domainIdentifier: providerIdentifier)
        }
    }

    private static func providerIdentifier(for url: URL) async -> String? {
        guard let domainIdentifier = await fileProviderDomainIdentifier(for: url) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                guard error == nil,
                      let domain = domains.first(where: { $0.identifier.rawValue == domainIdentifier }),
                      let manager = NSFileProviderManager(for: domain) else {
                    continuation.resume(returning: domainIdentifier)
                    return
                }

                #if os(iOS)
                let providerIdentifier = manager.providerIdentifier
                continuation.resume(
                    returning: providerIdentifier.isEmpty ? domainIdentifier : providerIdentifier
                )
                #else
                // `NSFileProviderManager.providerIdentifier` is unavailable on
                // macOS; the domain identifier is the best stable identity.
                _ = manager
                continuation.resume(returning: domainIdentifier)
                #endif
            }
        }
    }

    private static func fileProviderDomainIdentifier(for url: URL) async -> String? {
        await withCheckedContinuation { continuation in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { _, domainIdentifier, error in
                guard error == nil, let domainIdentifier else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: domainIdentifier.rawValue)
            }
        }
    }
}
