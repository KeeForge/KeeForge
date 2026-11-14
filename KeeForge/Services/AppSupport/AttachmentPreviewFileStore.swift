import Foundation

/// Manages short-lived plaintext temp files used to preview or share entry
/// attachments via QuickLook. Files live under a dedicated subdirectory of
/// `FileManager.temporaryDirectory`, are written with `.atomicProtected`
/// (Data Protection on iOS; FileVault covers at-rest encryption on macOS),
/// and are tracked so they can be removed as soon as a preview/share sheet
/// dismisses or the database locks.
@MainActor
protocol AttachmentPreviewFileStoring {
    static func write(_ data: Data, suggestedName: String, owner: UUID) throws -> URL
    static func remove(_ url: URL, owner: UUID)
}

@MainActor
enum AttachmentPreviewFileStore: AttachmentPreviewFileStoring {
    private static let subdirectoryName = "attachment-previews"
    private static var trackedURLs: [UUID: Set<URL>] = [:]

    private static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(subdirectoryName, isDirectory: true)
    }

    /// Writes `data` to a fresh temp file named `name` (falling back to a
    /// generic name when empty) and returns its URL. Call `remove(_:owner:)` once
    /// the consumer (QuickLook, share sheet) is done with the file.
    static func write(_ data: Data, suggestedName: String, owner: UUID) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) == false {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let sanitizedName = Self.sanitizedFilename(suggestedName)
        let url = directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(sanitizedName)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        try data.write(to: url, options: .atomicProtected)
        trackedURLs[owner, default: []].insert(url)
        return url
    }

    /// Removes a single previously written temp file (and its per-file
    /// directory) if present.
    static func remove(_ url: URL, owner: UUID) {
        guard trackedURLs[owner]?.remove(url) != nil else { return }
        if trackedURLs[owner]?.isEmpty == true {
            trackedURLs.removeValue(forKey: owner)
        }
        let containingDirectory = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: containingDirectory)
    }

    /// Deletes any preview files left behind by a previous process that
    /// terminated without locking (crash, force-quit, jetsam), so plaintext
    /// attachment bytes from an earlier session never persist into this one.
    /// Called once at app launch, before any preview is written; the
    /// `trackedURLs` guard makes stray later calls a no-op while a preview
    /// from any current session is live.
    static func purgeOrphanedFiles() {
        guard trackedURLs.isEmpty else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes only the owning session's previews on lock or reload.
    static func clear(owner: UUID) {
        for url in trackedURLs.removeValue(forKey: owner) ?? [] {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        if trackedURLs.isEmpty {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func sanitizedFilename(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "attachment" }

        let invalidCharacters = CharacterSet(charactersIn: "/\\:")
        let sanitized = trimmed.components(separatedBy: invalidCharacters).joined(separator: "_")
        return sanitized.isEmpty ? "attachment" : sanitized
    }
}
