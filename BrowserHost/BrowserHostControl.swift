#if os(macOS)
import Foundation

// Inspect only top-level string fields; application payloads stay opaque.
enum BrowserHostControl {
    static func isHost(_ data: Data) -> Bool {
        let bytes = Array(data)
        var index = 0
        func whitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        func stringRange() -> Range<Int>? {
            guard index < bytes.count, bytes[index] == 34 else { return nil }
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 92 { index += 1 }
                else if byte == 34 {
                    return start..<index
                }
            }
            return nil
        }
        func string() -> String? {
            guard let range = stringRange() else { return nil }
            return try? JSONDecoder().decode(String.self, from: Data(bytes[range]))
        }
        whitespace()
        guard index < bytes.count, bytes[index] == 123 else { return false }
        index += 1
        while index < bytes.count {
            whitespace()
            guard let key = string() else { return false }
            whitespace()
            guard index < bytes.count, bytes[index] == 58 else { return false }
            index += 1
            whitespace()
            if key == "t" { return string() == "host" }
            var depth = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 34 { guard stringRange() != nil else { return false }; continue }
                if depth == 0, byte == 44 || byte == 125 { break }
                if byte == 123 || byte == 91 { depth += 1 }
                if byte == 125 || byte == 93 { depth -= 1 }
                index += 1
            }
            guard index < bytes.count, bytes[index] == 44 else { return false }
            index += 1
        }
        return false
    }
}
#endif
