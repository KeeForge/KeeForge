<p align="center">
  <img src=".github/assets/KeeForge-iOS-Default-1024x1024@1x.png" alt="KeeForge app icon" width="128" />
</p>

<h1 align="center">KeeForge</h1>

<p align="center">
  A free, open-source KeePass manager for iPhone and iPad.
  <br />
  Native SwiftUI, local-first storage, AutoFill, passkeys, TOTP, Dropbox sync, and KDBX editing.
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/keeforge/id6759309295">
    <img alt="Download on the App Store" src="https://img.shields.io/badge/App%20Store-Download-0D96F6?style=for-the-badge&logo=appstore&logoColor=white" />
  </a>
  <img alt="Swift LoC" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fapi.codetabs.com%2Fv1%2Floc%3Fgithub%3Dcrazytan%2FKeeForge&query=%24%5B0%5D.linesOfCode&label=swift%20loc&color=orange&style=for-the-badge" />
  <a href="LICENSE">
    <img alt="License: GPLv3" src="https://img.shields.io/badge/license-GPLv3-blue?style=for-the-badge" />
  </a>
</p>

## Why KeeForge?

KeeForge is a native iOS KeePass client for people who want their vault to stay theirs. Open `.kdbx` databases from Files, iCloud Drive, local folders, or Dropbox; unlock with a master password, key file, or biometrics; then browse, search, edit, save, and AutoFill without handing your vault to a hosted password service.

## Highlights

| Area | What KeeForge Does |
| --- | --- |
| **KeePass compatibility** | Opens KDBX 4.x databases with AES-256 or ChaCha20 encryption and Argon2 KDF. Also opens password-only KDBX 3.1 databases. |
| **Local-first editing** | Create, edit, delete, and save entries and groups with conflict checks, timestamped backups, and unknown XML preservation. |
| **New databases** | Create new KDBX 4.x databases locally or directly inside Dropbox folders. |
| **Composite keys** | Unlock with password, key file, or both, including binary, hex, XML v1/v2 (`.key`/`.keyx`), and arbitrary key files. |
| **AutoFill** | Safari and app AutoFill, QuickType suggestions, credential creation from the extension, and Face ID gated unlock. |
| **Passkeys** | Detect and authenticate FIDO2/WebAuthn passkeys stored in KeePassXC-compatible custom fields. |
| **TOTP** | Live one-time password display, copy support, countdowns, and iOS 18+ verification-code AutoFill. |
| **Dropbox sync** | Native Dropbox account linking, cloud browsing, cached shared copies for AutoFill, and queued extension uploads. |
| **iPad ready** | Adaptive navigation keeps the database list visible on wider layouts while vaults open in a regular-width workspace. |
| **Security-minded** | AES-GCM in-memory secret encryption, failed-unlock backoff, screen-capture protection, local-only clipboard, decompression bomb limits, and constant-time HMAC comparison. |

## Privacy

KeeForge has no analytics, no background telemetry, and no crash-reporting SDKs. Vault data stays on device and in the storage locations you choose. Network access is limited to connected cloud providers, opt-in favicon fetching through DuckDuckGo, optional App Store purchases for the tip jar, and the in-app feedback form when you explicitly submit a message.

Read the [privacy policy](https://keeforge.com/privacy).

## Requirements

- iOS 17+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Swift 6 with strict concurrency
- Swift Package dependencies: [Argon2Swift](https://github.com/tmthecoder/Argon2Swift) and [SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox)

## Build From Source

```bash
cp BuildConfig.local.example.xcconfig BuildConfig.local.xcconfig
# Fill in DROPBOX_APP_KEY for Dropbox-enabled builds.
xcodegen generate
open KeeForge.xcodeproj
```

Select an iOS 17+ simulator or device, then build and run the `KeeForge` scheme.

For command-line verification, prefer the smallest relevant test slice:

```bash
xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet
```

## Project Map

```text
KeeForge/
├── App/              # App entry point, adaptive root shell, scene lifecycle
├── Models/           # KDBX parser/writer, crypto, edit draft, TOTP, passkeys
├── Services/         # Persistence, Dropbox sync, Keychain, bookmarks, AutoFill helpers
├── ViewModels/       # Database list, unlock, save, search, sort, TOTP state
├── Views/            # SwiftUI screens, editor, settings, tip jar, reusable controls
AutoFillExtension/    # AutoFill credential provider, passkey auth, credential creation
KeeForgeTests/        # Unit tests
KeeForgeUITests/      # XCUITest coverage
TestFixtures/         # Sample .kdbx databases and key files
```

## Docs

- [`CHANGELOG.md`](CHANGELOG.md) - version history
- [`ROADMAP.md`](ROADMAP.md) - planned product work and open priorities
- [`AGENTS.md`](AGENTS.md) - context for coding agents
- [`KeeForge/README.md`](KeeForge/README.md) - app-target architecture map
- [`AutoFillExtension/README.md`](AutoFillExtension/README.md) - extension constraints and shared-source notes
- [`docs/`](docs/) - implementation specs, audits, privacy notes, and longer-form design docs

## Support

- App Store: [KeeForge on the App Store](https://apps.apple.com/us/app/keeforge/id6759309295)
- Email: [support@keeforge.com](mailto:support@keeforge.com)
- Issues: [GitHub Issues](https://github.com/crazytan/KeeForge/issues)

## Contributing

Start with [`AGENTS.md`](AGENTS.md), then open the folder-local `README.md` closest to the code you are changing. The local docs are the fastest route to current architecture and test guidance.

## License

KeeForge is GPLv3 licensed. See [`LICENSE`](LICENSE) for details.
