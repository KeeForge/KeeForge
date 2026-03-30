# KeeForge

A free, native iOS KeePass password manager built with SwiftUI. Read-only in v1 — open any `.kdbx` (KDBX 4.x) database, browse and search entries, copy credentials, and autofill into apps and Safari.

## Features

- **KDBX 4.x** — AES-256 / ChaCha20 decryption with Argon2 key derivation
- **Composite keys** — unlock with password, key file, or both. Supports binary, hex, XML v1/v2 (`.key`/`.keyx`), and arbitrary file key formats
- **Passkey support** — detect and authenticate with FIDO2/WebAuthn passkeys stored in KeePassXC format
- **AutoFill** — credential provider extension works in Safari and apps. QuickType bar suggestions with Face ID
- **TOTP** — live one-time password display with countdown timer
- **Face ID / Touch ID** — biometric database unlock, auto-unlock on launch, biometric-gated password reveal/copy
- **Search** — full-text search across all entries
- **Sorting** — sort by title, created, or modified date; ascending or descending
- **Favicons** — opt-in website icon fetching via DuckDuckGo with disk cache
- **Security hardened** — AES-GCM in-memory secret encryption, exponential backoff on failed attempts, screen recording blur overlay, local-only clipboard, decompression bomb protection, constant-time HMAC comparison

## Requirements

- iOS 17+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Swift 6 (strict concurrency)
- No external SPM dependencies (except Argon2Swift for KDF)

## Build

```bash
xcodegen generate
open KeeForge.xcodeproj
```

Select an iOS 17+ simulator or device, then build and run.

## Usage

1. Open a `.kdbx` database from Files or iCloud Drive
2. Enter master password (and optional key file) to unlock
3. Browse groups, search entries, copy credentials
4. Use AutoFill in Safari and apps — credentials appear in the QuickType bar

## Project Structure

```
KeeForge/
├── App/              # App entry point, scene lifecycle
├── Models/           # KDBX parser, crypto, data models, TOTP, passkey
├── Services/         # Keychain, biometric, clipboard, favicon, screen protection
├── ViewModels/       # DatabaseViewModel, TOTPViewModel
├── Views/            # SwiftUI views (unlock, groups, entry detail, settings, tip jar)
AutoFillExtension/    # AutoFill credential provider + passkey authentication
KeeForgeTests/        # Unit tests
KeeForgeUITests/      # UI tests (XCUITest)
TestFixtures/         # Test .kdbx databases and key files
```

## Privacy

KeeForge collects zero data — no analytics, no telemetry, no crash reports. All data stays on device. Network requests are limited to opt-in favicon fetching (domain only, no credentials sent). See [privacy policy](docs/privacy-policy.md).

## Docs

- `CHANGELOG.md` — version history and roadmap
- `AGENTS.md` — context for AI coding agents
- `docs/` — implementation specs, security audit, privacy policy

## Support

- **Email:** [support@keeforge.com](mailto:support@keeforge.com)
- **Issues:** [GitHub Issues](https://github.com/crazytan/KeeForge/issues)

## Contributing

See [`AGENTS.md`](AGENTS.md) for project architecture, conventions, and coding guidelines — useful for both human contributors and AI coding agents.

## License

GPLv3 — see [LICENSE](LICENSE) for details.
