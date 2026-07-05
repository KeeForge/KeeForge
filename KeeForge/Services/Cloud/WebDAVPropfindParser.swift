import Foundation

/// A single resource discovered inside a PROPFIND multistatus response.
///
/// `path` is the decoded, server-relative path with the request's base prefix
/// stripped (e.g. `/Vaults/personal.kdbx`). `name` is the last path component.
struct WebDAVResource: Hashable, Sendable {
    let path: String
    let name: String
    let isFolder: Bool
    let eTag: String?
    let lastModified: Date?
    let contentLength: Int64?
}

/// Pure, dependency-free parser for WebDAV `PROPFIND` multistatus XML.
///
/// - Namespace-aware: matches `DAV:` local names only, so Nextcloud `oc:`/`nc:`
///   properties are ignored for free.
/// - Accepts properties only from `propstat` blocks whose status is `2xx`.
/// - Resolves and percent-decodes each `href` (relative or absolute), strips the
///   request base prefix, and skips the collection's own self entry.
/// - A resource is a folder iff its resourcetype contains `<D:collection/>`.
enum WebDAVPropfindParser {
    /// Parses the multistatus body.
    ///
    /// - Parameters:
    ///   - data: Raw XML response body.
    ///   - requestURL: The URL the PROPFIND was issued against, used to resolve
    ///     relative hrefs and to compute the base prefix that is stripped from
    ///     each resource path. Also used to identify and skip the self entry.
    ///   - includeSelf: Include the requested resource's own entry (needed for
    ///     Depth 0 probes of a single file, where the self entry IS the result).
    /// - Returns: The resources described by the response.
    static func parse(data: Data, requestURL: URL, includeSelf: Bool = false) throws -> [WebDAVResource] {
        let delegate = MultistatusDelegate(requestURL: requestURL, includeSelf: includeSelf)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate

        guard parser.parse() else {
            throw parser.parserError ?? WebDAVPropfindParseError.malformed
        }

        return delegate.resources
    }

    /// The last path component of a decoded, possibly trailing-slashed path.
    static func lastComponent(of path: String) -> String {
        let stripped = stripTrailingSlash(path)
        guard let slashIndex = stripped.lastIndex(of: "/") else {
            return stripped
        }
        return String(stripped[stripped.index(after: slashIndex)...])
    }

    static func stripTrailingSlash(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static let rfc1123Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// Parses an RFC 1123 `getlastmodified` / `Last-Modified` value.
    static func parseRFC1123(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return rfc1123Formatter.date(from: value)
    }
}

enum WebDAVPropfindParseError: Error, Equatable {
    case malformed
}

// MARK: - XMLParser delegate

private final class MultistatusDelegate: NSObject, XMLParserDelegate {
    private static let davNamespace = "DAV:"

    private let basePath: String
    private let selfDecodedPath: String
    private let includeSelf: Bool

    private(set) var resources: [WebDAVResource] = []

    // Per-<response> accumulation state.
    private var currentHref: String?
    private var currentIsFolder = false
    private var currentETag: String?
    private var currentLastModified: String?
    private var currentContentLength: String?

    // Per-<propstat> state.
    private var currentPropstatIsSuccess = false
    private var propstatETag: String?
    private var propstatLastModified: String?
    private var propstatContentLength: String?
    private var propstatIsFolder = false
    private var sawResourceTypeInPropstat = false

    private var elementStack: [String] = []
    private var textBuffer = ""

    init(requestURL: URL, includeSelf: Bool) {
        let decoded = requestURL.path.removingPercentEncoding ?? requestURL.path
        self.basePath = Self.normalizedDirectoryPath(decoded)
        self.selfDecodedPath = Self.stripTrailingSlash(decoded)
        self.includeSelf = includeSelf
        super.init()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        textBuffer = ""

        let isDAV = namespaceURI == Self.davNamespace
        let local = elementName

        if isDAV {
            switch local {
            case "response":
                resetResponseState()
            case "propstat":
                resetPropstatState()
            case "collection":
                // <D:collection/> nested under resourcetype marks a folder.
                if elementStack.last(where: { $0 == "dav:resourcetype" }) != nil {
                    propstatIsFolder = true
                }
            case "resourcetype":
                sawResourceTypeInPropstat = true
            default:
                break
            }
            elementStack.append("dav:" + local)
        } else {
            elementStack.append("other:" + local)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let isDAV = namespaceURI == Self.davNamespace
        let trimmed = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if isDAV {
            switch elementName {
            case "href":
                // Only capture the response-level href (direct child of response),
                // not hrefs that might appear inside other properties.
                if isDirectChildOfResponse() {
                    currentHref = trimmed
                }
            case "getetag":
                propstatETag = trimmed.isEmpty ? nil : trimmed
            case "getlastmodified":
                propstatLastModified = trimmed.isEmpty ? nil : trimmed
            case "getcontentlength":
                propstatContentLength = trimmed.isEmpty ? nil : trimmed
            case "status":
                if isDirectChildOfPropstat() {
                    currentPropstatIsSuccess = Self.isSuccessStatus(trimmed)
                }
            case "propstat":
                commitPropstatIfSuccessful()
            case "response":
                commitResponse()
            default:
                break
            }
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
        textBuffer = ""
    }

    // MARK: - Commit helpers

    private func commitPropstatIfSuccessful() {
        guard currentPropstatIsSuccess else { return }

        if let propstatETag { currentETag = propstatETag }
        if let propstatLastModified { currentLastModified = propstatLastModified }
        if let propstatContentLength { currentContentLength = propstatContentLength }
        if sawResourceTypeInPropstat {
            currentIsFolder = propstatIsFolder
        }
    }

    private func commitResponse() {
        guard let href = currentHref else { return }
        guard let decodedPath = Self.decodedPath(fromHref: href, requestURL: nil) else { return }

        // The requested resource's own entry: skipped for Depth 1 listings,
        // kept for Depth 0 single-file probes. Base-prefix stripping would
        // reduce its path to "/", so name it from the request path instead.
        if Self.stripTrailingSlash(decodedPath) == selfDecodedPath {
            guard includeSelf else { return }
            resources.append(
                WebDAVResource(
                    path: "/",
                    name: Self.lastComponent(of: selfDecodedPath),
                    isFolder: currentIsFolder,
                    eTag: currentETag,
                    lastModified: Self.parseRFC1123(currentLastModified),
                    contentLength: currentContentLength.flatMap { Int64($0) }
                )
            )
            return
        }

        let relativePath = Self.stripBasePrefix(from: decodedPath, base: basePath)
        let name = Self.lastComponent(of: relativePath)
        // Skip empty names (e.g. a bare "/" that survived stripping).
        guard !name.isEmpty else { return }

        let resource = WebDAVResource(
            path: relativePath,
            name: name,
            isFolder: currentIsFolder,
            eTag: currentETag,
            lastModified: Self.parseRFC1123(currentLastModified),
            contentLength: currentContentLength.flatMap { Int64($0) }
        )
        resources.append(resource)
    }

    // MARK: - State resets

    private func resetResponseState() {
        currentHref = nil
        currentIsFolder = false
        currentETag = nil
        currentLastModified = nil
        currentContentLength = nil
    }

    private func resetPropstatState() {
        currentPropstatIsSuccess = false
        propstatETag = nil
        propstatLastModified = nil
        propstatContentLength = nil
        propstatIsFolder = false
        sawResourceTypeInPropstat = false
    }

    // MARK: - Stack queries

    /// True when the element that just ended is a direct child of <D:response>.
    private func isDirectChildOfResponse() -> Bool {
        guard elementStack.count >= 2 else { return false }
        return elementStack[elementStack.count - 2] == "dav:response"
    }

    /// True when the element that just ended is a direct child of <D:propstat>.
    private func isDirectChildOfPropstat() -> Bool {
        guard elementStack.count >= 2 else { return false }
        return elementStack[elementStack.count - 2] == "dav:propstat"
    }

    // MARK: - Static helpers

    /// Decodes an href to its percent-decoded path. Absolute hrefs (with scheme)
    /// have their path extracted; relative hrefs are decoded directly.
    static func decodedPath(fromHref href: String, requestURL: URL?) -> String? {
        guard !href.isEmpty else { return nil }

        // Absolute URL: extract the path component.
        if let components = URLComponents(string: href), components.scheme != nil {
            let path = components.percentEncodedPath
            return path.removingPercentEncoding ?? path
        }

        // Relative href: it is already a path (possibly with query, which we drop).
        let pathOnly = href.split(separator: "?", maxSplits: 1).first.map(String.init) ?? href
        return pathOnly.removingPercentEncoding ?? pathOnly
    }

    /// Strips the request base prefix from a decoded resource path, returning a
    /// path that begins with "/". Case-sensitive prefix match (paths are
    /// case-sensitive on most WebDAV servers).
    static func stripBasePrefix(from path: String, base: String) -> String {
        guard base != "/", !base.isEmpty else {
            return ensureLeadingSlash(path)
        }

        if path == base || path == stripTrailingSlash(base) {
            return "/"
        }

        if path.hasPrefix(base) {
            let remainder = String(path.dropFirst(base.count))
            return ensureLeadingSlash(remainder)
        }

        return ensureLeadingSlash(path)
    }

    static func lastComponent(of path: String) -> String {
        WebDAVPropfindParser.lastComponent(of: path)
    }

    static func normalizedDirectoryPath(_ path: String) -> String {
        if path.isEmpty { return "/" }
        return path.hasSuffix("/") ? path : path + "/"
    }

    static func stripTrailingSlash(_ path: String) -> String {
        WebDAVPropfindParser.stripTrailingSlash(path)
    }

    static func ensureLeadingSlash(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/" + path
    }

    static func isSuccessStatus(_ statusLine: String) -> Bool {
        // e.g. "HTTP/1.1 200 OK"
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return false }
        return (200..<300).contains(code)
    }

    static func parseRFC1123(_ value: String?) -> Date? {
        WebDAVPropfindParser.parseRFC1123(value)
    }
}
