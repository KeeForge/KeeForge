<p align="center">
  <img src=".github/assets/KeeForge-iOS-Default-1024x1024@1x.png" alt="KeeForge app icon" width="128" />
</p>

<h1 align="center">KeeForge</h1>

<p align="center">
  English | <a href="docs/i18n/README.de.md">Deutsch</a> | <a href="docs/i18n/README.fr.md">Français</a> | <a href="docs/i18n/README.es.md">Español</a> | <a href="docs/i18n/README.zh-Hans.md">简体中文</a> | <a href="docs/i18n/README.zh-Hant.md">繁體中文</a>
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
  <a href="https://testflight.apple.com/join/mPAT4f1a">
    <img alt="Join the public beta on TestFlight" src="https://img.shields.io/badge/TestFlight-Public%20Beta-1F8AF0?style=for-the-badge&logo=apple&logoColor=white" />
  </a>
  <img alt="Requires iOS 18.0 or later" src="https://img.shields.io/badge/iOS-18.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white" />
  <img alt="Requires macOS 15.0 or later" src="https://img.shields.io/badge/macOS-15.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white" />
  <img alt="Swift LoC" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Ftokei.kojix2.net%2Fapi%2Fgithub%2FKeeForge%2FKeeForge%2Flanguages&query=%24.data.languages.Swift.code&label=swift%20loc&color=orange&style=for-the-badge" />
  <a href="LICENSE">
    <img alt="License: GPLv3" src="https://img.shields.io/badge/license-GPLv3-blue?style=for-the-badge" />
  </a>
</p>

## Why KeeForge?

KeeForge is a native iOS KeePass client for people who want their vault to stay theirs. Open `.kdbx` databases from Files, iCloud Drive, local folders, Dropbox, OneDrive, or WebDAV servers such as Nextcloud and Synology; unlock with a master password, key file, or biometrics; then browse, search, edit, save, and AutoFill without handing your vault to a hosted password service.

## Public Beta

**[Join the KeeForge beta on TestFlight](https://testflight.apple.com/join/mPAT4f1a)**

> [!WARNING]
> **Test with a copy of your database, not your primary vault.** Beta builds are unreviewed, and they share the App Store app's bundle identifier and container — so they open your real `.kdbx` files.

## Highlights

| Area | What KeeForge Does |
| --- | --- |
| **KeePass compatibility** | Reads and writes KDBX 4.x databases with AES-256, ChaCha20, or Twofish encryption and AES-KDF, Argon2d, or Argon2id. Also opens KDBX 3.1 databases in read-only mode. |
| **Local-first editing** | Create, edit, move, and delete entries and groups; and save with conflict checks, timestamped backups, and preservation of entry history and unknown XML. |
| **New databases** | Create new KDBX 4.x databases locally or directly inside Dropbox, OneDrive, and WebDAV folders. |
| **Composite keys** | Unlock with password, key file, or both, including binary, hex, XML v1/v2 (`.key`/`.keyx`), and arbitrary key files. |
| **AutoFill** | Safari and app AutoFill, QuickType suggestions, credential creation from the extension, and Face ID gated unlock. |
| **Passkeys** | Detect and authenticate FIDO2/WebAuthn passkeys stored in KeePassXC-compatible custom fields. |
| **TOTP** | Live one-time password display, copy support, countdowns, and iOS 18+ verification-code AutoFill. |
| **Cloud sync** | Native Dropbox, OneDrive, and WebDAV browsing and read/write sync, cached shared copies for AutoFill, queued extension uploads, and conflict checks. |
| **Attachments** | View KeePass entry attachments, preview supported files with QuickLook, and share them from short-lived protected temporary files. Attachment editing is not yet supported. |
| **iPad ready** | Adaptive navigation uses a split-view vault workspace on wider layouts while keeping the compact iPhone flow focused and native. |
| **Security** | AES-GCM in-memory secret encryption, failed-unlock backoff, decompression bomb limits, and constant-time HMAC comparison. |

## Privacy

KeeForge has no analytics, no background telemetry, and no crash-reporting SDKs. Vault data stays on device and in the storage locations you choose. Network access is limited to connected cloud providers, opt-in favicon fetching through DuckDuckGo, optional App Store purchases for the tip jar, and the in-app feedback form when you explicitly submit a message.

Anything you copy stays on the device you copied it on, never syncing to your other devices, and it clears itself after a short while or when you lock the database. KeeForge also hides what is on screen while your screen is being recorded or mirrored.

Read the [privacy policy](https://keeforge.com/privacy).

## Data Safety

KeeForge takes data safety very seriously: a password manager must never corrupt your vault or silently lose any part of it. Before any change ships, automated tests verify that:

- **Nothing gets lost when you save.** Every kind of edit is saved and read back piece by piece — passwords, notes, attachments, entry history, and even data from other KeePass apps that KeeForge doesn't recognize must all come back exactly as they went in.
- **Your file is protected before it's touched.** KeeForge refuses to overwrite changes made from elsewhere while you had the file open, writes a timestamped backup before every save, and rejects damaged databases outright instead of loading partial data.
- **An independent program agrees.** Every release must pass a gate where KeePassXC — a widely used KeePass app that shares no code with KeeForge — opens KeeForge-written databases, decrypts the passwords, and confirms attachments match bit for bit. Databases created by other KeePass software must likewise open in KeeForge and stay readable elsewhere after KeeForge saves them.

For the technically curious, the test suite is mapped in [`KeeForgeTests/README.md`](KeeForgeTests/README.md) and the pre-release verification gate in [`ci_scripts/README.md`](ci_scripts/README.md).

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
KeeForgeMac/          # Native macOS app (preparing its first release)
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

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for build requirements, how to build from source, the pull request workflow, the Developer Certificate of Origin sign-off requirement, and licensing terms. Start with [`AGENTS.md`](AGENTS.md), then open the folder-local `README.md` closest to the code you are changing.

## License

KeeForge is GPLv3 licensed. See [`LICENSE`](LICENSE) for details.
