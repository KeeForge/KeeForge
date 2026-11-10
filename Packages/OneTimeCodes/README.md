# OneTimeCodes

Time-based one-time codes in Swift: TOTP (RFC 6238) on HOTP (RFC 4226), RFC 4648 Base32, a strict `otpauth://totp` parser, and the KeeOTP query format. It works on plain secret bytes; storing and unsealing them is up to you.

Swift 6, iOS 18+ / macOS 15+, Foundation and CryptoKit only.

## Codes

```swift
import OneTimeCodes

guard let secret = Base32.decode("JBSWY3DPEHPK3PXP"),
      let parameters = TOTPParameters(secret: secret, period: 30, digits: 6, algorithm: .sha1) else {
    return // empty or not Base32
}
let code = TOTP.code(for: parameters, at: .now) // "123456"
let remaining = TOTP.secondsRemaining(period: parameters.period, at: .now)
```

`TOTPParameters` copies the secret into a `SymmetricKey`, so you can wipe your buffer afterwards. It returns nil only for an empty secret and clamps the rest: a period below 1 second becomes 1, digits outside 1...9 move to the nearest end.

## Base32

`Base32.decode` is lenient the way pasted secrets need: either case, with spaces, line breaks, and `=` skipped. `Base32.encode` writes unpadded uppercase. `Base32.canonicalSecret` returns a value only when it is already canonical: nothing to skip, no set trailing bits, and at least one byte.

## Enrollment links

```swift
let uri = try OTPAuthURI(string: scannedText)
uri.secret      // canonical Base32
uri.issuer      // the issuer parameter, else the label prefix
uri.accountName
uri.period, uri.digits, uri.algorithm
uri.rawURI      // the input, trimmed, with only the scheme and authority lowercased
```

Only `totp` links are accepted. HOTP and Steam links throw `OTPAuthURIError.unsupportedType`; a missing or undecodable secret, an unknown algorithm, digits outside 1...9, or a period below 1 throw the matching case. Duplicate parameters keep their first value.

## KeeOTP

`KeeOTPQuery.rewriting(_:secret:period:digits:algorithm:)` updates the `key=...&step=...` query KeeOTP and KeeOtp2 store, changing only the settings it writes and appending the ones the query omits.

## Not here yet

KeeForge still reads stored TOTP fields in its KDBX parser and writes them in its serializer. To take that over, this package would need:

- a lenient mode for stored `otpauth` values: any host after a case-sensitive `otpauth://` prefix, the first value of duplicate parameters, the secret kept as text and decoded only when a code is generated, out-of-range or unparsable period and digits replaced by 30 and 6, and an unknown algorithm read as SHA-1;
- KeeOTP query parsing, the inverse of `KeeOTPQuery.rewriting`: only `key` required, `type` (if present) `TOTP`, `step` above 0, `size` 6 or 8, duplicate settings refused, and `key` decoded by its declared `encoding` (strict unpadded Base32 by default, canonical Base64, hex, or UTF-8);
- KeePass 2.x `TimeOtp-*` reading: the first non-empty of `TimeOtp-Secret`, `-Hex`, `-Base32`, `-Base64`, decoded by that field's encoding, with `TimeOtp-Period`, `-Length`, and `-Algorithm` (KeePass names or the short tokens), and the legacy `TOTP Seed` / `TOTP Settings` pair;
- the matching writers for those fields.

## Tests and coverage

```bash
swift test
scripts/coverage.sh
```

`scripts/coverage.sh` reports line, region, and function coverage for `Sources/OneTimeCodes` and fails below its thresholds. LLVM records no branch coverage for Swift; region coverage, which counts each side of every condition, stands in for it.
