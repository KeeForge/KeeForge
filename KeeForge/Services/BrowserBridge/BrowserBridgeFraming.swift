#if os(macOS)
import Foundation

enum BrowserBridgeFraming {
    static let maximumAppPayload = 65_536
    static let maximumExtensionPayload = 1_048_576
    /// The largest reply plaintext whose sealed `msg` frame (tag, base64 and envelope) still fits toward the extension.
    static let maximumReplyPlaintext = (maximumExtensionPayload - 64) / 4 * 3 - 16

    enum Direction { case towardApp, towardExtension
        var limit: Int { self == .towardApp ? maximumAppPayload : maximumExtensionPayload }
    }

    static func encode(_ payload: Data, toward direction: Direction) throws -> Data {
        guard payload.count <= direction.limit else { throw BrowserBridgeDecodingError.oversizedFrame }
        let length = UInt32(payload.count)
        return Data((0..<4).map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) }) + payload
    }

    static func decode(_ frame: Data, toward direction: Direction) throws -> Data {
        guard frame.count >= 4 else { throw BrowserBridgeDecodingError.invalidFrame }
        let length = frame.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard length <= direction.limit else { throw BrowserBridgeDecodingError.oversizedFrame }
        guard frame.count == Int(length) + 4 else { throw BrowserBridgeDecodingError.invalidFrame }
        return Data(frame.dropFirst(4))
    }
}
#endif
