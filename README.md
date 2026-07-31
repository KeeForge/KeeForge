<p align="center">
  <img src=".github/assets/KeeForge-iOS-Default-1024x1024@1x.png" alt="KeeForge app icon" width="128" />
</p>

<h1 align="center">KeeForge</h1>

<p align="center">
  English | <a href="README.de.md">Deutsch</a>
</p>

<p align="center">
  A free, open-source KeePass manager for iPhone and iPad.
  <br />
  Native SwiftUI, local-first storage, AutoFill, passkeys, TOTP, cloud sync, KDBX editing, and attachment viewing.
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/keeforge/id6759309295">
    <img alt="Download on the App Store" src="https://img.shields.io/badge/App%20Store-Download-0D96F6?style=for-the-badge&logo=appstore&logoColor=white" />
  </a>
  <img alt="Swift LoC" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Ftokei.kojix2.net%2Fapi%2Fgithub%2FKeeForge%2FKeeForge%2Flanguages&query=%24.data.languages.Swift.code&label=swift%20loc&color=orange&style=for-the-badge" />
  <a href="LICENSE">
    <img alt="License: GPLv3" src="https://img.shields.io/badge/license-GPLv3-blue?style=for-the-badge" />
  </a>
</p>

## Why KeeForge?

KeeForge is a native iOS KeePass client for people who want their vault to stay theirs. Open `.kdbx` databases from Files, iCloud Drive, local folders, Dropbox, OneDrive, or WebDAV servers such as Nextcloud and Synology; unlock with a master password, key file, or biometrics; then browse, search, edit, save, and AutoFill without handing your vault to a hosted password service.

## Public Beta

New versions go out on TestFlight before they reach the App Store.

**[Join the KeeForge beta on TestFlight](https://testflight.apple.com/join/mPAT4f1a)**

> [!WARNING]
> **Test with a copy of your database, not your primary vault.** TestFlight builds are pre-release versions that have not been through App Store review, and they can carry bugs the released app does not. The beta installs under the same bundle identifier and app container as the App Store build, so it replaces that install and opens the same real `.kdbx` files, cloud connections, and saved keys. Duplicate a database first and point the beta at the copy. Keep your own backups either way.

> [!NOTE]
> **The beta is not open continuously.** Places are capped at 300 testers, and joining closes whenever the group is full or a new version is still going through Apple's beta review. The link then reads "This beta isn't accepting any new testers right now" — that is normal, and it reopens on its own. Check back later.

## Highlights

| Area | What KeeForge Does |
| --- | --- |
| **KeePass compatibility** | Reads and writes KDBX 4.x databases with AES-256, ChaCha20, or Twofish encryption and AES-KDF, Argon2d, or Argon2id. Also opens KDBX 3.1 databases in read-only mode. |
| **Local-first editing** | Create, edit, and delete entries; create and delete groups; and save with conflict checks, timestamped backups, and preservation of entry history and unknown XML. |
| **New databases** | Create new KDBX 4.x databases locally or directly inside Dropbox, OneDrive, and WebDAV folders. |
| **Composite keys** | Unlock with password, key file, or both, including binary, hex, XML v1/v2 (`.key`/`.keyx`), and arbitrary key files. |
| **AutoFill** | Safari and app AutoFill, QuickType suggestions, credential creation from the extension, and Face ID gated unlock. |
| **Passkeys** | Detect and authenticate FIDO2/WebAuthn passkeys stored in KeePassXC-compatible custom fields. |
| **TOTP** | Live one-time password display, copy support, countdowns, and iOS 18+ verification-code AutoFill. |
| **Cloud sync** | Native Dropbox, OneDrive, and WebDAV browsing and read/write sync, cached shared copies for AutoFill, queued extension uploads, and conflict checks. |
| **Attachments** | View KeePass entry attachments, preview supported files with QuickLook, and share them from short-lived protected temporary files. Attachment editing is not yet supported. |
| **iPad ready** | Adaptive navigation uses a split-view vault workspace on wider layouts while keeping the compact iPhone flow focused and native. |
| **Security-minded** | AES-GCM in-memory secret encryption, failed-unlock backoff, local-only clipboard, decompression bomb limits, and constant-time HMAC comparison. Screen-privacy differs by platform: iOS shields the app while it is being recorded (`UIScreen.isCaptured`); macOS blurs its windows whenever it loses focus and, by default, best-effort blocks screenshots/recordings (`NSWindow.sharingType`, which ScreenCaptureKit-based capture can bypass on macOS 15+). The macOS behavior refers to the experimental native macOS app (the `KeeForgeMac` target) in this repo, currently on hold and unreleased. See [`docs/macos-security-notes.md`](docs/macos-security-notes.md). |

## Privacy

KeeForge has no analytics, no background telemetry, and no crash-reporting SDKs. Vault data stays on device and in the storage locations you choose. Network access is limited to connected cloud providers, opt-in favicon fetching through DuckDuckGo, optional App Store purchases for the tip jar, and the in-app feedback form when you explicitly submit a message.

Read the [privacy policy](https://keeforge.com/privacy).

## Requirements

- iOS 18+
- Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Swift 6 with strict concurrency
- Swift Package dependencies: [Argon2Swift](https://github.com/tmthecoder/Argon2Swift), [SwiftyDropbox](https://github.com/dropbox/SwiftyDropbox), [Microsoft Authentication Library](https://github.com/AzureAD/microsoft-authentication-library-for-objc), and the vendored [KeeForgeTwofish](Vendor/KeeForgeTwofish) package

## Build From Source

```bash
cp BuildConfig.local.example.xcconfig BuildConfig.local.xcconfig
# Fill in DROPBOX_APP_KEY and ONEDRIVE_CLIENT_ID for provider-enabled builds.
xcodegen generate
open KeeForge.xcodeproj
```

Select an iOS 18+ simulator or device, then build and run the `KeeForge` scheme.

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
├── Extensions/       # Shared platform-compat helpers
├── Models/           # KDBX parser/writer, crypto, edit draft, TOTP, passkeys
├── Resources/        # String catalogs and asset catalogs
├── Services/         # Persistence, cloud sync, Keychain, bookmarks, attachments, AutoFill helpers
├── ViewModels/       # Database list, unlock, save, search, sort, TOTP state
├── Views/            # SwiftUI screens, editor, settings, tip jar, reusable controls
AutoFillExtension/    # AutoFill credential provider, passkey auth, credential creation
KeeForgeMac/          # Experimental native macOS app (unreleased, on hold)
KeeForgeMacUITests/   # XCUITest coverage for the macOS app
KeeForgeTests/        # Unit tests
KeeForgeUITests/      # XCUITest coverage
TestFixtures/         # Sample .kdbx databases and key files
Vendor/               # Vendored KeeForgeTwofish Swift package
ci_scripts/           # Xcode Cloud bootstrap and release gate scripts
scripts/              # Local dev tooling
```

## Docs

- [`CHANGELOG.md`](CHANGELOG.md) - version history
- [`ROADMAP.md`](ROADMAP.md) - planned product work and open priorities
- [`AGENTS.md`](AGENTS.md) - context for coding agents
- [`KeeForge/README.md`](KeeForge/README.md) - app-target architecture map
- [`AutoFillExtension/README.md`](AutoFillExtension/README.md) - extension constraints and shared-source notes
- [`SECURITY.md`](SECURITY.md) - vulnerability disclosure policy
- [`docs/`](docs/) - implementation specs, audits, and longer-form design docs

## Support

- App Store: [KeeForge on the App Store](https://apps.apple.com/us/app/keeforge/id6759309295)
- Email: [support@keeforge.com](mailto:support@keeforge.com)
- Issues: [GitHub Issues](https://github.com/KeeForge/KeeForge/issues)

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the pull request workflow, Developer Certificate of Origin sign-off requirement, and licensing terms. Start with [`AGENTS.md`](AGENTS.md), then open the folder-local `README.md` closest to the code you are changing.

## License

KeeForge is GPLv3 licensed. See [`LICENSE`](LICENSE) for details.
