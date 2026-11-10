# Test vectors

The vectors are inline in the test files; this lists where each comes from. Prefer published known answers over round trips: a round trip cannot catch a wrong hash, truncation, or alphabet.

| Vectors | Source | Test |
| --- | --- | --- |
| HOTP truncated values and 6-digit codes for counts 0–9 | [RFC 4226](https://www.rfc-editor.org/rfc/rfc4226) Appendix D | `TOTPTests.testHOTPMatchesRFC4226AppendixDTruncatedValuesAndCodes` |
| TOTP codes for SHA-1, SHA-256, SHA-512 at all six times, with the 20-, 32-, and 64-byte seeds | [RFC 6238](https://www.rfc-editor.org/rfc/rfc6238) Appendix B | `TOTPTests.testTOTPMatchesTheFullRFC6238AppendixBTable` |
| SHA-1 code for the 5-byte secret `00 01 02 FE FF` at counter 1 | Python `hmac` / `hashlib` reference computation | `TOTPTests.testTOTPMatchesIndependentReferenceForArbitraryBinarySecret` |
| `""` through `"foobar"`, encode and decode | [RFC 4648](https://www.rfc-editor.org/rfc/rfc4648) section 10 | `Base32Tests` |
| `otpauth://totp` examples and label forms | [Google Authenticator Key URI Format](https://github.com/google/google-authenticator/wiki/Key-Uri-Format) | `OTPAuthURITests.test_googleKeyURIFormat_*` |
