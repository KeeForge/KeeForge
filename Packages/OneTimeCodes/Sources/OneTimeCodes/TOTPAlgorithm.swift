/// The HMAC hash behind a one-time code.
///
/// `rawValue` is the short `otpauth` and KeeOTP token, and apps persist it:
/// never change it.
public enum TOTPAlgorithm: String, Codable, Sendable, CaseIterable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    /// KeePass 2.x's `TimeOtp-Algorithm` value. KeePass matches these names
    /// exactly and generates no code for anything else.
    public var keePassName: String {
        switch self {
        case .sha1: "HMAC-SHA-1"
        case .sha256: "HMAC-SHA-256"
        case .sha512: "HMAC-SHA-512"
        }
    }

    /// Also reads the short tokens, which some writers put in
    /// `TimeOtp-Algorithm`.
    public init?(keePassName: String) {
        switch keePassName {
        case "HMAC-SHA-1", "SHA1": self = .sha1
        case "HMAC-SHA-256", "SHA256": self = .sha256
        case "HMAC-SHA-512", "SHA512": self = .sha512
        default: return nil
        }
    }
}
