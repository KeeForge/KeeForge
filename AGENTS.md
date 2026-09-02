# AGENTS.md

Entry point for coding agents working on KeeForge. This file is intentionally brief; most useful guidance now lives in folder-local `README.md` files next to the code.

## High level guidance

- Do not preserve backward compatibility unless required by the existing install base. Remove obsolete paths instead of adding compatibility layers, fallbacks, or migrations.
- Choose the simplest implementation that fully meets the current requirements. Avoid speculative abstractions, configuration, and indirection.
- Grow the system in layers. Start from the smallest version that works end to end, and add each new capability on top of a product that already works. Never trade a working product for unfinished complexity.
- Keep components modular and concerns clearly separated.
- Prefer established, well-maintained libraries when they reduce overall complexity or improve reliability. Do not reimplement common functionality without a clear reason.
- Lean on the dependencies already in the project before writing your own implementation or adding packages. Do not assume a library lacks a capability without checking its documentation and types.
- Make architectural decisions for the long term. Do not accept a stopgap that only works for now and is meant to be replaced later.

## Project Snapshot

- Native iOS KeePass manager for KDBX 4.x databases; also reads KDBX 3.1 (read-only)
- Swift 6, SwiftUI, iOS 18+ / macOS 15+, `@Observable`, strict concurrency
- XcodeGen build graph: edit `project.yml`, then regenerate `KeeForge.xcodeproj`
- Main targets: `KeeForge`, `KeeForgeMac`, `KeeForgeAutoFill`, `KeeForgeMacAutoFill`, `KeeForgeTests`, `KeeForgeMacTests`, `KeeForgeUITests`, `KeeForgeMacUITests`. The macOS targets are being prepared for their first release and have not shipped yet; the remaining checklist is CHANGELOG.md's "## macOS App" section, and macOS work is logged there rather than under `## Unreleased`.

## Open The Local Doc First

- `KeeForge/README.md` — app-target map and cross-cutting flows
- `KeeForge/App/README.md` — app lifecycle, root navigation, scene handling
- `KeeForge/Models/README.md` — parser, writer, edit-draft, and core data-model guidance
- `KeeForge/Services/README.md` — storage, local save, cloud sync, keychain, bookmarks, device integrations
- `KeeForge/Services/{AppSupport,AutoFill,Cloud,Persistence,Security}/README.md` — per-subfolder service maps and constraints
- `KeeForge/ViewModels/README.md` — list, unlock, save, search, sort, and TOTP state ownership
- `KeeForge/Views/README.md` — screen ownership and UI/testing conventions
- `KeeForge/Views/{Cloud,Components,DatabaseList,Entry,Group,SearchAndTags,Settings,TOTP,Unlock}/README.md` — per-feature screen maps
- `KeeForge/Extensions/README.md` — shared Swift extension helpers
- `KeeForge/Resources/README.md` — string catalogs, assets, and resource conventions
- `KeeForgeMac/README.md` — macOS target constraints
- `AutoFillExtension/README.md` — extension constraints and shared-source notes
- `KeeForgeTests/README.md` — unit-test map and selection rules
- `KeeForgeTests/Support/README.md` — shared fixtures, fakes, spies, and assertion helpers
- `KeeForgeUITests/README.md` — XCUITest workflow and flake-avoidance guidance
- `KeeForgeMacUITests/README.md` — macOS XCUITest workflow
- `TestFixtures/README.md` — bundled databases, passwords, and key files
- `Vendor/KeeForgeTwofish/README.md` — vendored Twofish cipher package
- `ci_scripts/README.md` — Xcode Cloud bootstrap and `run_kdbx_compatibility_gate.sh`, the required local release gate
- `scripts/README.md` — local dev tooling
- `.github/AGENTS.md` — CI workflow gating map (named `AGENTS.md` because GitHub renders a `.github/README.md` as the repo front-page README)
- `docs/README.md` — historical archive of past design specs, audits, and notes (may not match current code), except `docs/macos-security-notes.md`, a living doc kept truthful with the code

## Agent Orchestration

If you are a very powerful model like Fable/Opus/GPT 5.6 Sol, feel free to delegate implementation and test to sub-agents with appropriate models.

Repo skills live in `.agents/skills/` (`release`, `spec-creator`, `publish-app-store-version`, `keeforge-github-issues`), symlinked under `.claude/skills/`; `release` defines the release-branch → TestFlight soak → App Store flow (`release/{major}.{minor}` branches, `rc/{version}-b{build}` candidate tags, `v{version}` as a record of the shipped build).

Use `keeforge-github-issues` for every GitHub issue mutation.

## Repo-Wide Rules

### Coding Styles

- Use `@Observable`, not `ObservableObject` / `@Published`.
- Use `NavigationStack` + `NavigationPath`, not `NavigationView`.
- Keep crypto, parsing, and secret handling off the main thread.
- Treat these `KeeForge/Models/` files as stable core: `KDBXParser.swift`, `KDBX3Parser.swift`, `KDBXWriter.swift`, `KDBXXMLSerializer.swift`, `KDBXCrypto.swift`, `KDBXOuterCipher.swift`, `OpaqueXMLNodes.swift`, `DatabaseDraft.swift`, `EntryEdit.swift`, `Entry.swift`, `Group.swift`, `EncryptedValue.swift`, `TOTPGenerator.swift`. Change them only for real bugs or intentional format/security work, and add focused tests.
- No force unwraps outside tests.
- Keep comments minimal. A comment is only warranted when the code cannot explain itself — a non-obvious constraint, a format/platform quirk, or the reason behind a surprising choice. Don't restate what the code already says, don't narrate control flow, and don't leave changelog-style notes ("was X, now Y") or review/audit chatter in the source; that belongs in the commit message. Prefer one short line over a paragraph.

### Workflows

- Put temporary agent artifacts such as handoff prompts, investigation notes, and scratch scripts under `scratch/`; it is gitignored and must not contain files intended to ship.
- App and Mac targets use folder globs in `project.yml`, so `xcodegen generate` alone picks up new files. Invariant: the `KeeForgeAutoFill` and `KeeForgeMacAutoFill` allow-lists in `project.yml` must stay byte-identical — edit both together.
- When adding new files, update the nearest folder-local `README.md` if the file changes that folder's map, ownership notes, or workflow guidance.
- Do not update `docs/specs` for new code changes unless explicitly asked. These specs are mostly historical artifacts, not living implementation docs.
- When changing code shared with `AutoFillExtension`, keep extension-safe imports/APIs and target membership in sync.
- When adding or changing database creation, edit operations, KDBX parser/writer behavior, protected fields, unknown XML handling, AutoFill save, cloud save, or local save, update `KeeForgeTests/KDBXCompatibilityTests.swift` and the compatibility artifact gate if the supported compatibility matrix changes.
- Preserve accessibility identifiers or update the relevant UI tests in the same change.
- Update `CHANGELOG.md` for feature or bug-fix commits, only under `## Unreleased` — except macOS-only work. It's okay to skip if the bug fix is for an unreleased feature. Keep changelog updates concise, simple and user facing, don't include implementation details unless necessary.

### Localization

- UI text is localized with Xcode String Catalogs (`.xcstrings`), source language `en`. Currently shipped locales: `en`, `de`, `fr`, `es`, `zh-Hans`, `zh-Hant`.
- Reach user-facing strings via `String(localized:)` (or SwiftUI's automatic catalog lookup) — never hardcode display text.
- Every English key needs a translation in each shipped locale; `KeeForgeTests/LocalizationTests.swift` fails on missing or drifted translations (currently checks `de`, `fr`, `es`, `zh-Hans`, and `zh-Hant`) and also runs in `KeeForgeMacTests`. Run it after touching any catalog.
- Catalog mechanics — the four-catalog file map, adding a new locale, and normalizing `.xcstrings` — live in `KeeForge/Resources/README.md`.

### Research Notes

- When asked for reference implementations, consult `https://github.com/keepassium/keepassium` and `https://github.com/strongbox-password-safe/Strongbox`.

### Version Control Notes

- Every commit must be DCO signed off (`git commit -s`); the "DCO" status check is required.

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
- The RC workflow (`.github/workflows/ios18-rc-tests.yml`) tests on an iOS 18 iPhone SE (3rd generation) simulator — reproduce RC failures there.

### macOS Test Strategy

Mac XCUITest is the slowest and most fragile lever available: it needs an unlocked login session, grabs real screen and input focus, and serializes against every other Xcode run on the machine. Reach for it last.

- Put Mac behavior in `@Observable` view models and cover it in `KeeForgeMacTests`, which runs headless and shares the iOS unit sources. Keep `KeeForgeMacUITests` a thin smoke layer over flows that only exist as UI.
- For Mac-specific layout deltas, prefer SwiftUI previews or the `MacScreenshotAuditUITests` capture pass over driving the app with new assertions.
- What a given change has to test is a table in `KeeForgeMac/README.md` ("What Mac Work Has To Test"). Read the row for your change before you call it done.
- Shared SwiftUI is the default and keeps macOS nearly free — but a targeted AppKit view is the right answer where SwiftUI on Mac cannot express the interaction at all (keyboard navigation in search results and the tag browser are the known cases). Take the escape hatch deliberately, not as a workaround for a flaky test.
- To capture the Mac app's own windows (screenshots, visual audits), disable screen-capture blocking with the launch argument `-KeeForge.blockScreenCapture NO` — the argument-domain override of `SettingsService.blockScreenCapture`. This pair must come *before* the bare `-ui-testing` flag (`MacScreenshotAuditUITests` inserts it there).

## Security Reminders

- Secrets are re-encrypted in memory with a per-session `SymmetricKey`; lock clears the session key and invalidates `EncryptedValue` access.
- Composite keys live in Keychain, not raw master passwords.
- Local saves compare the open-time SHA-512 before overwrite, create timestamped backups, and refresh the shared cached copy for AutoFill.
- App Group and security-scoped bookmark behavior affect both the app and AutoFill extension.
- Network egress stays limited to cloud sync, opt-in favicon fetching (DuckDuckGo, `icons.duckduckgo.com`), and the user-initiated feedback form (`feedback.keeforge.com`).
