import Foundation

/// Discovers KDBX files that Finder/iTunes file sharing placed in the app's
/// Documents directory and registers them as local databases.
///
/// Finder "replace" over USB is delete+recopy, which strands the existing
/// bookmark of a Documents-resident reference. The scan drives every resident
/// reference through `DatabaseListStore.locateDatabaseFile(for:)` — the single
/// heal implementation, which rebinds stranded references to
/// `Documents/<filename>` (same id, nickname, key file, settings) and reseeds
/// the AutoFill cache — then registers files no reference claims. Only files
/// carrying the 8-byte KDBX magic are touched; anything else the user dropped
/// (key files, notes) is left alone.
enum DocumentsVaultScanner {
    /// Returns whether the database list changed. Safe to call from any
    /// thread; every list mutation goes through `DatabaseListStore`, which
    /// serializes internally.
    @discardableResult
    static func scan(directory: URL = DatabaseListStore.documentsDirectoryURL) -> Bool {
        let candidates = databaseFileCandidates(in: directory)
        var didChange = false

        let residentSnapshot = DatabaseListStore.databases.filter(\.isDocumentsResident)
        for reference in residentSnapshot {
            switch DatabaseListStore.locateDatabaseFile(for: reference) {
            case .available(let url):
                rederiveIdentityIfNeeded(for: reference, at: url)
                reconcileSharedCache(for: reference, with: url)
            case .inTrash, nil:
                // Never auto-remove: absence is ambiguous during a Finder
                // delete+recopy window, and keeping the entry preserves the
                // rebind-on-restore path.
                break
            }
        }

        // A heal or identity re-derivation surfaces as a bookmark or
        // filename/flag change on the stored reference.
        let storedAfterHeals = DatabaseListStore.databases
        for reference in residentSnapshot {
            guard let stored = storedAfterHeals.first(where: { $0.id == reference.id }) else { continue }
            if stored.bookmarkData != reference.bookmarkData
                || stored.filename != reference.filename
                || stored.isDocumentsResident != reference.isDocumentsResident {
                didChange = true
                break
            }
        }

        for url in candidates {
            // `add(url:)` throws `duplicateFile` for paths an existing
            // reference (including one just rebound) already resolves to.
            if (try? DatabaseListStore.add(url: url)) != nil {
                didChange = true
            }
        }

        return didChange
    }

    /// Top-level regular files bearing the KDBX magic. `.skipsHiddenFiles`
    /// excludes `.Trash`; the regular-file check excludes directories such as
    /// `Inbox`.
    private static func databaseFileCandidates(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { return false }
            return DocumentPickerService.hasKDBXMagic(at: url)
        }
    }

    /// A Files-app rename or move keeps the bookmark valid but strands the
    /// stored identity: path-keyed rebinding is keyed on
    /// `Documents/<filename>`, so the stored filename must track the real
    /// one, and a file moved out of top-level Documents must drop the flag.
    /// Scanner-only on purpose — `locateDatabaseFile` also runs in the
    /// AutoFill extension, where `documentsDirectoryURL` is the extension's
    /// container and any re-derivation would be wrong.
    private static func rederiveIdentityIfNeeded(for reference: DatabaseReference, at url: URL) {
        let filename = url.lastPathComponent
        let isTopLevel = DatabaseListStore.isTopLevelDocumentsFile(url)
        guard filename != reference.filename || isTopLevel == false else { return }
        DatabaseListStore.rederiveDocumentsIdentity(
            for: reference.id,
            filename: filename,
            isDocumentsResident: isTopLevel
        )
    }

    // MARK: - Shared-cache reconciliation

    private struct SourceFingerprint: Equatable {
        let path: String
        let size: Int
        let modificationDate: Date?
    }

    /// Last successfully reconciled source fingerprint per reference id;
    /// process-lifetime only. Lets repeated scans skip both byte reads when
    /// the on-disk file has not changed. `nonisolated(unsafe)` + lock matches
    /// the store's static-state idiom.
    private nonisolated(unsafe) static var reconciledFingerprints: [UUID: SourceFingerprint] = [:]
    private static let fingerprintLock = NSLock()

    /// A same-path Finder replace keeps the bookmark valid but leaves the
    /// AutoFill shared cache stale (and an add-time mid-copy snapshot may
    /// have cached truncated bytes); resync whenever disk and cache disagree.
    private static func reconcileSharedCache(for reference: DatabaseReference, with url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let fingerprint = makeFingerprint(for: url) else { return }
        let previous = fingerprintLock.withLock { reconciledFingerprints[reference.id] }
        guard fingerprint != previous else { return }

        guard let onDiskData = try? CoordinatedFileReader.readData(from: url),
              DocumentPickerService.hasKDBXHeader(onDiskData) else {
            return
        }

        if let cachedURL = DatabaseListStore.cachedDatabaseURL(for: reference.id),
           let cachedData = try? Data(contentsOf: cachedURL),
           cachedData == onDiskData {
            fingerprintLock.withLock { reconciledFingerprints[reference.id] = fingerprint }
            return
        }

        guard (try? DatabaseListStore.cacheDatabaseCopy(onDiskData, for: reference.id)) != nil else { return }
        fingerprintLock.withLock { reconciledFingerprints[reference.id] = fingerprint }
    }

    private static func makeFingerprint(for url: URL) -> SourceFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        return SourceFingerprint(
            path: url.path,
            size: values.fileSize ?? -1,
            modificationDate: values.contentModificationDate
        )
    }
}
