# KeeForge

[![Swift LoC](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fapi.codetabs.com%2Fv1%2Floc%3Fgithub%3Dcrazytan%2FKeeForge&query=%24%5B0%5D.linesOfCode&label=swift%20loc&color=orange)](https://github.com/crazytan/KeeForge)

A free, native iPhone and iPad KeePass password manager built with SwiftUI. Open `.kdbx` databases, unlock with passwords, key files, or biometrics, browse and edit entries, and AutoFill into apps and Safari.

## Features

- **KDBX 4.x** — AES-256 / ChaCha20 decryption with Argon2 key derivation
- **iPad support** — adaptive navigation keeps the database list visible on larger layouts while the selected vault opens in a regular-width workspace
- **Composite keys** — unlock with password, key file, or both. Supports binary, hex, XML v1/v2 (`.key`/`.keyx`), and arbitrary file key formats
- **Passkey support** — detect and authenticate with FIDO2/WebAuthn passkeys stored in KeePassXC format
- **AutoFill** — credential provider extension works in Safari and apps. QuickType bar suggestions with Face ID
- **TOTP** — live one-time password display with countdown timer
- **Face ID / Touch ID** — biometric database unlock, auto-unlock on launch, biometric-gated password reveal/copy
- **Search** — full-text search across all entries
- **Sorting** — sort by title, created, or modified date; ascending or descending
- **Entry editing** — create, edit, delete, and save entries with password generation, conflict handling, and read-only safeguards
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
cp BuildConfig.local.example.xcconfig BuildConfig.local.xcconfig
# Fill in DROPBOX_APP_KEY
xcodegen generate
open KeeForge.xcodeproj
```

The build uses `BuildConfig.local.xcconfig` for local Dropbox configuration and
`BuildMetadata.xcconfig` for generated values such as the git commit hash.
Select an iOS 17+ simulator or device, then build and run.

## Usage

1. Add one or more `.kdbx` databases from Files, iCloud Drive, or supported cloud providers
2. Select a database, then unlock with a master password, key file, biometrics, or a supported combination
3. Browse groups and entries, search, edit, and save changes
4. Use AutoFill in Safari and apps — credentials appear in the QuickType bar

## Project Structure

```
KeeForge/
├── App/              # App entry point, adaptive root shell, scene lifecycle
├── Models/           # KDBX parser/writer, crypto, edit draft, TOTP, passkey
├── Services/         # Database list persistence, local save, cloud sync, Keychain, bookmarks
├── ViewModels/       # DatabaseListViewModel, DatabaseViewModel, TOTPViewModel
├── Views/            # SwiftUI views (database list, unlock, group/entry browsing, editor, settings, tip jar)
AutoFillExtension/    # AutoFill credential provider + passkey authentication
KeeForgeTests/        # Unit tests
KeeForgeUITests/      # UI tests (XCUITest)
TestFixtures/         # Test .kdbx databases and key files
```

## Privacy

KeeForge has no analytics, no background telemetry, and no crash-reporting SDKs. Your vault data stays on device and in the cloud storage you configure. Outbound network requests are limited to the cloud providers you connect, opt-in favicon fetching (domain only, no credentials sent), and the optional in-app feedback form — which only transmits anything when you tap Send. See the [privacy policy](https://keeforge.com/privacy).

## Docs

- `CHANGELOG.md` — version history
- `ROADMAP.md` — planned product work and open priorities
- `AGENTS.md` — context for AI coding agents
- `KeeForge/**/README.md`, `AutoFillExtension/README.md`, `KeeForgeTests/README.md`, `TestFixtures/README.md` — task-oriented folder docs for contributors and coding agents
- `docs/` — implementation specs, security audit, privacy policy

## Support

- **Email:** [support@keeforge.com](mailto:support@keeforge.com)
- **Issues:** [GitHub Issues](https://github.com/crazytan/KeeForge/issues)

## Contributing

Start with [`AGENTS.md`](AGENTS.md), then open the folder-local `README.md` closest to the code you are changing. The local docs are the fastest route to current architecture and test guidance.

## License

GPLv3 — see [LICENSE](LICENSE) for details.
