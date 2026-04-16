import CryptoKit
import UIKit

enum FaviconService: Sendable {
    // MARK: - Configuration

    private static let faviconBaseURL = "https://icons.duckduckgo.com/ip3/"
    private static let ttlSeconds: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private static let cacheDirectoryName = "favicons"

    // MARK: - Cache Directory

    static var cacheDirectory: URL {
        let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedVaultStore.appGroupID
        ) ?? FileManager.default.temporaryDirectory
        return groupURL.appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }

    // MARK: - Domain Extraction

    static func extractDomain(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Add scheme if missing so URL parser works
        let withScheme: String
        if trimmed.contains("://") {
            withScheme = trimmed
        } else {
            withScheme = "https://" + trimmed
        }

        guard let url = URL(string: withScheme),
              let host = url.host(percentEncoded: false),
              !host.isEmpty else {
            return nil
        }

        let lower = host.lowercased()

        // Reject localhost
        if lower == "localhost" { return nil }

        // Reject IP addresses (IPv4 and IPv6)
        if lower.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) {
            return nil
        }

        // Reject private/internal domains
        if isPrivateDomain(lower) { return nil }

        return lower
    }

    // MARK: - Private Domain Detection

    private static let privateTLDs: Set<String> = [
        ".local", ".internal", ".lan", ".home",
        ".localdomain", ".corp", ".intranet", ".arpa",
    ]

    static func isPrivateDomain(_ host: String) -> Bool {
        // Single-label hostnames (no dots) are likely internal
        if !host.contains(".") { return true }

        // Private TLDs
        for tld in privateTLDs where host.hasSuffix(tld) {
            return true
        }

        // IPv6 loopback and link-local
        if host == "::1" || host.hasPrefix("fe80:") { return true }

        // Check for private/reserved IPv4 ranges
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _):                          return true  // 10.0.0.0/8
            case (172, 16...31):                   return true  // 172.16.0.0/12
            case (192, 168):                       return true  // 192.168.0.0/16
            case (169, 254):                       return true  // 169.254.0.0/16 link-local
            case (127, _):                         return true  // 127.0.0.0/8 loopback
            default: break
            }
        }

        return false
    }

    // MARK: - Cache Key

    static func cacheKey(for domain: String) -> String {
        let hash = SHA256.hash(data: Data(domain.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Cache Path

    private static func cachePath(for domain: String) -> URL {
        let key = cacheKey(for: domain)
        return cacheDirectory.appendingPathComponent(key)
    }

    // MARK: - Ensure Cache Directory

    private static func ensureCacheDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: cacheDirectory.path) {
            try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Cached Image

    static func cachedImage(for domain: String) -> UIImage? {
        let path = cachePath(for: domain)
        let fm = FileManager.default

        guard fm.fileExists(atPath: path.path) else { return nil }

        // Check TTL
        if let attrs = try? fm.attributesOfItem(atPath: path.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) > ttlSeconds {
            try? fm.removeItem(at: path)
            return nil
        }

        guard let data = try? Data(contentsOf: path) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Fetch

    static func fetchFavicon(for domain: String) async -> UIImage? {
        guard let url = URL(string: "\(faviconBaseURL)\(domain).ico") else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  !data.isEmpty else {
                return nil
            }

            guard let image = UIImage(data: data) else { return nil }

            // Save to disk cache
            ensureCacheDirectory()
            let path = cachePath(for: domain)
            try? data.write(to: path, options: [.atomic, .completeFileProtection])

            return image
        } catch {
            return nil
        }
    }

    // MARK: - Primary API

    /// Returns a cached favicon or fetches one. Returns nil if unavailable.
    static func favicon(for domain: String) async -> UIImage? {
        if let cached = cachedImage(for: domain) {
            return cached
        }
        return await fetchFavicon(for: domain)
    }

    // MARK: - Clear Cache

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    // MARK: - Cache Size

    static var cacheSizeBytes: Int64 {
        let fm = FileManager.default
        let path = cacheDirectory.path
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }
}
