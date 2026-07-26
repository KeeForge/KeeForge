# AGENTS.md

Entry point for coding agents working on KeeForge. This file is intentionally brief; most useful guidance now lives in folder-local `README.md` files next to the code.

## Project Snapshot

- Native iOS KeePass manager for KDBX 4.x databases; also reads KDBX 3.1 (read-only)
- Swift 6, SwiftUI, iOS 18+ / macOS 14+, `@Observable`, strict concurrency
- XcodeGen build graph: edit `project.yml`, then regenerate `KeeForge.xcodeproj`
- Main targets: `KeeForge`, `KeeForgeMac`, `KeeForgeAutoFill`, `KeeForgeMacAutoFill`, `KeeForgeTests`, `KeeForgeMacTests`, `KeeForgeUITests`, `KeeForgeMacUITests`. The macOS app targets exist but are ON HOLD and must not ship (see CHANGELOG.md's "## macOS App" section).
- Current product areas: multi-database list, local and cloud-backed vaults (Dropbox/OneDrive/WebDAV), full local edit/save, database creation, attachments viewing (read-only), AutoFill including per-database/per-group selection, TOTP, passkey authentication (no registration), password generator, tip jar, screen protection, opt-in favicons, feedback form, experimental unreleased macOS app

## Open The Local Doc First

- `KeeForge/README.md` — app-target map and cross-cutting flows
- `KeeForge/App/README.md` — app lifecycle, root navigation, scene handling
- `KeeForge/Models/README.md` — parser, writer, edit-draft, and core data-model guidance
- `KeeForge/Services/README.md` — storage, local save, cloud sync, keychain, bookmarks, device integrations
- `KeeForge/Services/{AppSupport,AutoFill,Cloud,Persistence,Security}/README.md` — per-subfolder service maps and constraints
- `KeeForge/ViewModels/README.md` — list, unlock, save, search, sort, and TOTP state ownership
- `KeeForge/Views/README.md` — screen ownership and UI/testing conventions
- `KeeForge/Extensions/README.md` — shared Swift extension helpers
- `KeeForge/Resources/README.md` — string catalogs, assets, and resource conventions
- `KeeForgeMac/README.md` — macOS target constraints
- `AutoFillExtension/README.md` — extension constraints and shared-source notes
- `KeeForgeTests/README.md` — unit-test map and selection rules
- `KeeForgeUITests/README.md` — XCUITest workflow and flake-avoidance guidance
- `KeeForgeMacUITests/README.md` — macOS XCUITest workflow
- `TestFixtures/README.md` — bundled databases, passwords, and key files
- `Vendor/KeeForgeTwofish/README.md` — vendored Twofish cipher package
- `ci_scripts/README.md` — Xcode Cloud bootstrap behavior, plus `run_kdbx_compatibility_gate.sh`, the required local release gate
- `scripts/README.md` — local dev tooling
- `.github/README.md` — CI workflow gating map
- `docs/README.md` — mostly an archive of past design specs, audits, and notes (historical; not guaranteed to match current code), except `docs/macos-security-notes.md`, a living doc that must be kept truthful with the code

## Agent Orchestration

If you are a very powerful model like Fable 5, feel free to delegate implementation and test to sub-agents with appropriate models. If you are Claude, feel free to use Codex CLI with a strong model (e.g., GPT 5.6 sol xhigh) for subagents' tasks, too. This is important to keep context windows manageable.

Repo skills live in `.agents/skills/` (`release`, `spec-creator`, `publish-app-store-version`), with symlinks under `.claude/skills/`. The `release` skill defines the `rc/*` → `v*` tag release flow.

## Repo-Wide Rules

### Coding Styles

- Use `@Observable`, not `ObservableObject` / `@Published`.
- Use `NavigationStack` + `NavigationPath`, not `NavigationView`.
- Keep crypto, parsing, and secret handling off the main thread.
- Treat these `KeeForge/Models/` files as stable core: `KDBXParser.swift`, `KDBX3Parser.swift`, `KDBXWriter.swift`, `KDBXXMLSerializer.swift`, `KDBXCrypto.swift`, `KDBXOuterCipher.swift`, `OpaqueXMLNodes.swift`, `DatabaseDraft.swift`, `EntryEdit.swift`, `Entry.swift`, `Group.swift`, `EncryptedValue.swift`, `TOTPGenerator.swift`. Change them only for real bugs or intentional format/security work, and add focused tests.
- No force unwraps outside tests.

### Workflows

- Put temporary agent artifacts such as handoff prompts, investigation notes, and scratch scripts under `scratch/`; it is gitignored and must not contain files intended to ship.
- App and Mac targets use folder globs in `project.yml`, so new files are picked up by `xcodegen generate` alone. The real invariant: the two AutoFill allow-lists in `project.yml` (`KeeForgeAutoFill` and `KeeForgeMacAutoFill`) must stay byte-identical — edit both together.
- When adding new files, update the nearest folder-local `README.md` if the file changes that folder's map, ownership notes, or workflow guidance.
- Do not update `docs/specs` for new code changes unless explicitly asked. These specs are mostly historical artifacts, not living implementation docs.
- When changing code shared with `AutoFillExtension`, keep extension-safe imports/APIs and target membership in sync.
- When adding or changing database creation, edit operations, KDBX parser/writer behavior, protected fields, unknown XML handling, AutoFill save, cloud save, or local save, update `KeeForgeTests/KDBXCompatibilityTests.swift` and the compatibility artifact gate if the supported compatibility matrix changes.
- Preserve accessibility identifiers or update the relevant UI tests in the same change.
- Do not use MCP tools to run Xcode tests. Start a fresh `bash` session and run the test command there instead.
- Update `CHANGELOG.md` for feature or bug-fix commits. Add entries only under `## Unreleased`. Exception: macOS-only work goes under the `## macOS App (in development)` section at the top of `CHANGELOG.md`, not `## Unreleased`. It's okay to skip if the bug fix is for an unreleased feature.

### Localization

- UI text is localized with Xcode String Catalogs (`.xcstrings`), source language `en`. Currently shipped locales: `en`, `de`.
- Four catalogs: `Localizable.xcstrings` + `InfoPlist.xcstrings` under `KeeForge/Resources/`, mirrored under `AutoFillExtension/`. The same four catalogs also serve the macOS targets. Reach user-facing strings via `String(localized:)` (or SwiftUI's automatic catalog lookup) — never hardcode display text.
- Every English key needs a translation in each shipped locale; `KeeForgeTests/LocalizationTests.swift` fails the test suite on missing or drifted translations (it currently checks `de` specifically), and also runs in `KeeForgeMacTests`. Run it after touching any catalog.
- When adding a new locale, also translate the user-facing docs: the root `README.md` only (folder-local READMEs and developer docs stay English-only, see `README.de.md`), and the separate `keeforge.com` website repo (its content needs the same locale coverage).
- Xcode reserializes `.xcstrings` into its own canonical style on open/build, so editing a catalog as plain JSON causes a large reordering diff next time. After any programmatic catalog edit, run `swift scripts/normalize-xcstrings.swift` (no args = all catalogs; `--check` is available for verification) so committed bytes match Xcode's.

### Research Notes

- When asked for reference implementations, consult `https://github.com/keepassium/keepassium` and `https://github.com/strongbox-password-safe/Strongbox`.

### Version Control Notes

- Every commit must be DCO signed off (`git commit -s`); the "DCO" status check is required.
- Prefer committing on the current branch, or on `main` if already there. Avoid creating new branches when possible, and push directly instead of waiting for a separate branch workflow. This direct-push guidance applies to maintainer/agent sessions on this repo; external contributors follow `CONTRIBUTING.md`'s fork + PR workflow.

## Build And Test

```bash
xcodegen generate

xcodebuild build -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet

xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
  -destination 'platform=macOS' \
  -only-testing:KeeForgeMacTests/DatabaseViewModelTests -quiet
```

- Always prefer the smallest relevant test slice.
- Always use `-only-testing:`.
- Do not run the full UI suite unless explicitly asked.
- `KeeForgeMacTests` compiles the `KeeForgeTests` folder; there is no `KeeForgeMacTests` directory.
- The iOS-18 RC GitHub workflow (`.github/workflows/ios18-rc-tests.yml`) tests on iPhone SE (3rd generation) with iOS 18 — use that simulator to reproduce RC failures.
- If Xcode reports stale project references after file moves, regenerate with `xcodegen generate`.

## Security Reminders

- Secrets are re-encrypted in memory with a per-session `SymmetricKey`; lock clears the session key and invalidates `EncryptedValue` access.
- Composite keys live in Keychain, not raw master passwords.
- Local saves compare the open-time SHA-512 before overwrite, create timestamped backups, and refresh the shared cached copy for AutoFill.
- App Group and security-scoped bookmark behavior affect both the app and AutoFill extension.
- Network access should stay limited to the three explicit egress points: cloud sync, opt-in favicon fetching (DuckDuckGo, `icons.duckduckgo.com`), and the user-initiated feedback form (`feedback.keeforge.com`).
