/// The query string KeeOTP and KeeOtp2 store in an entry's `otp` field, as in
/// `key=SECRET&step=30&size=6&otpHashMode=SHA1`.
public enum KeeOTPQuery {
    /// `rawQuery` with new code settings, changed as little as possible.
    ///
    /// Each of `key`, `encoding`, `step`, `size`, and `otpHashMode` is matched
    /// case-insensitively after percent-decoding, and only its first
    /// occurrence is rewritten, keeping the original name spelling. Every other
    /// component keeps its bytes and position. A setting with no component is
    /// appended under its canonical name, since KeeOtp2 omits defaults.
    ///
    /// A nil `secret` leaves `key` and `encoding` alone; a new one is
    /// written as `key=secret&encoding=Base32`, so pass canonical Base32.
    public static func rewriting(
        _ rawQuery: String,
        secret: String?,
        period: Int,
        digits: Int,
        algorithm: TOTPAlgorithm
    ) -> String {
        let replacements: [String: String?] = [
            "key": secret,
            "encoding": secret == nil ? nil : "Base32",
            "step": String(period),
            "size": String(digits),
            "otphashmode": algorithm.rawValue,
        ]
        var pendingNames = Set(replacements.keys)
        var components = rawQuery.split(separator: "&", omittingEmptySubsequences: false).map { component -> String in
            let parts = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let decodedName = String(parts[0]).removingPercentEncoding else {
                return String(component)
            }
            let name = decodedName.lowercased()
            guard pendingNames.contains(name) else { return String(component) }
            pendingNames.remove(name)
            guard case let replacement?? = replacements[name] else { return String(component) }
            return "\(parts[0])=\(replacement)"
        }
        for name in ["key", "encoding", "step", "size", "otphashmode"] where pendingNames.contains(name) {
            guard case let value?? = replacements[name] else { continue }
            components.append("\(name == "otphashmode" ? "otpHashMode" : name)=\(value)")
        }
        return components.joined(separator: "&")
    }
}
