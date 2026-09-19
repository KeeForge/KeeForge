import Foundation

struct FTPListEntry: Equatable, Sendable {
    let name: String
    let isFolder: Bool
    let size: Int64?
    /// The server's `YYYYMMDDHHMMSS[.sss]` UTC stamp exactly as sent. Kept
    /// verbatim so revs compare at whatever precision the server offers.
    let modifiedStamp: String?

    var modifiedDate: Date? {
        modifiedStamp.flatMap(FTPListingParser.date(fromTimeVal:))
    }
}

/// Pure parsers for FTP listings and reply payloads. MLSD/MLST (RFC 3659) is
/// the machine-readable format; `LIST` output is only loosely specified, so
/// the fallback understands the two layouts servers actually send (Unix
/// `ls -l` and IIS/DOS) and skips anything else.
enum FTPListingParser {
    // MARK: - MLSD / MLST

    /// Parses one MLSD/MLST entry: `fact=value;fact=value; name`. Returns nil
    /// for the `.`/`..` entries (`cdir`/`pdir`) and for lines without facts.
    static func parseMachineEntry(_ rawLine: String) -> FTPListEntry? {
        let line = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine
        guard let separator = line.firstIndex(of: " ") else { return nil }

        let factsPart = line[..<separator]
        var name = String(line[line.index(after: separator)...])
        guard !name.isEmpty else { return nil }

        var facts: [String: String] = [:]
        for fact in factsPart.split(separator: ";") {
            guard let equals = fact.firstIndex(of: "=") else { continue }
            let key = fact[..<equals].lowercased()
            facts[key] = String(fact[fact.index(after: equals)...])
        }
        guard let type = facts["type"]?.lowercased() else { return nil }
        if type == "cdir" || type == "pdir" { return nil }

        // MLST answers with the full pathname; listings only need the leaf.
        if name.contains("/") {
            name = lastComponent(of: name)
        }

        return FTPListEntry(
            name: name,
            isFolder: type == "dir",
            size: facts["size"].flatMap { Int64($0) },
            modifiedStamp: facts["modify"].flatMap { isTimeVal($0) ? $0 : nil }
        )
    }

    // MARK: - LIST

    static func parseListLine(_ line: String) -> FTPListEntry? {
        parseUnixListLine(line) ?? parseDOSListLine(line)
    }

    /// `drwxr-xr-x 2 owner group 4096 Jan 01 12:00 name`. The owner and group
    /// columns vary (some servers print only one), so the date is located by
    /// its month token and the name is everything after the time-or-year.
    private static func parseUnixListLine(_ line: String) -> FTPListEntry? {
        guard let typeCharacter = line.first, "-dl".contains(typeCharacter) else { return nil }

        let tokens = tokenRanges(in: line)
        guard tokens.count >= 6 else { return nil }

        for index in 2..<(tokens.count - 3) {
            let month = line[tokens[index]]
            guard monthNames.contains(month.lowercased()),
                  let size = Int64(line[tokens[index - 1]]),
                  let day = Int(line[tokens[index + 1]]), (1...31).contains(day) else {
                continue
            }
            let timeOrYear = line[tokens[index + 2]]
            guard timeOrYear.contains(":") || (timeOrYear.count == 4 && Int(timeOrYear) != nil) else {
                continue
            }

            var name = String(line[tokens[index + 3].lowerBound...])
            if typeCharacter == "l", let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            guard isListableName(name) else { return nil }

            return FTPListEntry(
                name: name,
                isFolder: typeCharacter == "d",
                size: typeCharacter == "d" ? nil : size,
                modifiedStamp: nil
            )
        }
        return nil
    }

    /// `01-31-24  09:15PM  <DIR>  name` or `01-31-24  09:15PM  1234  name`.
    private static func parseDOSListLine(_ line: String) -> FTPListEntry? {
        let tokens = tokenRanges(in: line)
        guard tokens.count >= 4 else { return nil }

        let date = line[tokens[0]]
        guard date.count >= 8, date.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "/" }) else { return nil }
        guard line[tokens[1]].contains(":") else { return nil }

        let sizeOrDir = line[tokens[2]]
        let isFolder = sizeOrDir.uppercased() == "<DIR>"
        let size = Int64(sizeOrDir)
        guard isFolder || size != nil else { return nil }

        let name = String(line[tokens[3].lowerBound...])
        guard isListableName(name) else { return nil }

        return FTPListEntry(name: name, isFolder: isFolder, size: size, modifiedStamp: nil)
    }

    private static func tokenRanges(in line: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in line.indices {
            if line[index] == " " || line[index] == "\t" {
                if let tokenStart = start {
                    ranges.append(tokenStart..<index)
                    start = nil
                }
            } else if start == nil {
                start = index
            }
        }
        if let start {
            ranges.append(start..<line.endIndex)
        }
        return ranges
    }

    private static func isListableName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
    }

    private static let monthNames: Set<String> = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]

    // MARK: - Timestamps

    /// RFC 3659 `time-val`: `YYYYMMDDHHMMSS` with an optional `.fraction`.
    static func isTimeVal(_ value: String) -> Bool {
        let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts[0].count == 14, parts[0].allSatisfy(\.isASCIIDigit) else { return false }
        if parts.count == 2 {
            return !parts[1].isEmpty && parts[1].allSatisfy(\.isASCIIDigit)
        }
        return true
    }

    static func date(fromTimeVal value: String) -> Date? {
        guard isTimeVal(value) else { return nil }
        let digits = Array(value.prefix(14))
        func number(_ range: Range<Int>) -> Int? { Int(String(digits[range])) }

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = number(0..<4)
        components.month = number(4..<6)
        components.day = number(6..<8)
        components.hour = number(8..<10)
        components.minute = number(10..<12)
        components.second = number(12..<14)
        guard components.isValidDate, let date = components.date else { return nil }

        if let dot = value.firstIndex(of: "."), let fraction = Double("0" + value[dot...]) {
            return date.addingTimeInterval(fraction)
        }
        return date
    }

    // MARK: - Passive-mode replies

    /// `229 Entering Extended Passive Mode (|||6446|)` — RFC 2428 lets the
    /// server pick the delimiter, so it is read from the payload.
    static func extendedPassivePort(from message: String) -> UInt16? {
        guard let open = message.firstIndex(of: "("),
              let close = message[open...].firstIndex(of: ")") else { return nil }
        let payload = message[message.index(after: open)..<close]
        guard let delimiter = payload.first else { return nil }
        let fields = payload.split(separator: delimiter, omittingEmptySubsequences: false)
        guard fields.count == 5, let port = UInt16(fields[3]), port > 0 else { return nil }
        return port
    }

    /// `227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)`. Only the port is used:
    /// the data connection always goes to the control host, because the
    /// advertised address is routinely a private one behind NAT and trusting
    /// it would let a server steer the client at another host.
    static func passivePort(from message: String) -> UInt16? {
        var numbers: [Int] = []
        var current = ""
        for character in message + " " {
            if character.isASCIIDigit {
                current.append(character)
                continue
            }
            if !current.isEmpty {
                numbers.append(Int(current) ?? -1)
                current = ""
            }
            if character != "," {
                if numbers.count >= 6 { break }
                numbers.removeAll()
            }
        }
        guard numbers.count >= 6 else { return nil }
        let fields = Array(numbers.prefix(6))
        guard fields.allSatisfy({ (0...255).contains($0) }) else { return nil }
        let port = fields[4] * 256 + fields[5]
        guard port > 0 else { return nil }
        return UInt16(port)
    }

    static func lastComponent(of path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    /// Everything before the last component: `""` for a bare name (the login
    /// directory) and `"/"` for a name at the root.
    static func parentPath(of path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed = trimmed.dropLast()
        }
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
