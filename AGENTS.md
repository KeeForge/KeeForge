# AGENTS.md

Entry point for coding agents working on KeeForge. This file holds the repo-wide rules. Each folder's `AGENTS.md` holds that folder's invariants, ownership boundaries, and test mapping.

## High level guidance

- Do not preserve backward compatibility unless required by the existing install base. Remove obsolete paths instead of adding compatibility layers, fallbacks, or migrations.
- Choose the simplest implementation that fully meets the current requirements. Avoid speculative abstractions, configuration, and indirection.
- Grow the system in layers. Start from the smallest version that works end to end, and add each new capability on top of a product that already works. Never trade a working product for unfinished complexity.
- Keep components modular and concerns clearly separated.
- Use the project's existing dependencies first, then established, well-maintained libraries, before writing your own. Check a library's documentation and types before assuming it lacks a capability.
- Make architectural decisions for the long term. Do not accept a stopgap that only works for now and is meant to be replaced later.

## Project Snapshot

- Native iPhone, iPad, and Mac KeePass manager for KDBX 4.x; also reads KDBX 3.1 (read-only)
- Swift 6, SwiftUI, iOS 18+ / macOS 15+, `@Observable`, strict concurrency
- XcodeGen build graph: edit `project.yml`, then regenerate `KeeForge.xcodeproj`; target-membership rules live in `KeeForge/AGENTS.md`
- Xcode Cloud runs the `KeeForgeCloudUnitTests`, `KeeForgeCloudUIA`, and `KeeForgeCloudUIB` schemes; the partition rules are in `ci_scripts/AGENTS.md`.
- Main targets: `KeeForge`, `KeeForgeMac`, `KeeForgeAutoFill`, `KeeForgeMacAutoFill`, `KeeForgeTests`, `KeeForgeMacTests`, `KeeForgeUITests`, `KeeForgeMacUITests`

## Find The Right Doc

Before changing a folder, read its `AGENTS.md` and each parent's up to this file, or its `README.md` where it has no `AGENTS.md` (`KeeForgeMac/` also has `SECURITY.md`). `docs/README.md` indexes `docs/`; local dev tooling is in `scripts/README.md`.

## Repo-Wide Rules

### Coding Styles

- Use `@Observable`, not `ObservableObject` / `@Published`.
- Use `NavigationStack` with typed routes, not `NavigationView`. Keep SwiftUI navigation objects out of shared view models.
- Keep crypto, parsing, and secret handling off the main thread.
- Treat these `KeeForge/Models/` files as stable core: `KDBXParser.swift`, `KDBX3Parser.swift`, `KDBXWriter.swift`, `KDBXXMLSerializer.swift`, `KDBXCrypto.swift`, `KDBXOuterCipher.swift`, `OpaqueXMLNodes.swift`, `DatabaseDraft.swift`, `EntryEdit.swift`, `Entry.swift`, `Group.swift`, `EncryptedValue.swift`, `TOTPGenerator.swift`. Change them only for real bugs or intentional format/security work, and add focused tests.
- No force unwraps outside tests.
- Comment only what the code cannot say: a non-obvious constraint, a format or platform quirk, or the reason for a surprising choice. One short line, never a restatement, control-flow narration, or change history ("was X, now Y"); that belongs in the commit message.

### Workflows

- Keep temporary agent artifacts in the main checkout's gitignored `scratch/`, never a linked worktree's. Find the main checkout with the first entry in `git worktree list --porcelain`.
- `scratch/` may be emptied at any time. Release artifacts and evidence a later step needs go in the main checkout's `build/releases/` (`ci_scripts/release_dir.sh`; layout in `.agents/skills/prepare-release/references/shared.md`).
- Update the folder's `AGENTS.md` when an invariant, ownership boundary, or test mapping changes. Do not add file maps, identifier lists, or history. Leave historical `docs/specs` alone unless explicitly asked.
- Preserve accessibility identifiers or update the relevant UI tests in the same change. `KeeForgeUITests` and `KeeForgeMacUITests` share one identifier surface, so update both.
- Add concise, user-facing changes to `CHANGELOG.md` under `## Unreleased`; fixes for unreleased features may skip it.
- Every commit must be DCO signed off (`git commit -s`); the "DCO" status check is required.
- For reference implementations, consult `https://github.com/keepassium/keepassium` and `https://github.com/strongbox-password-safe/Strongbox`.

### Localization

- UI text uses Xcode String Catalogs (`.xcstrings`), source language `en`. Shipped locales: `en`, `de`, `fr`, `es`, `zh-Hans`, `zh-Hant`, `ja`, `it`, `ru`.
- Reach user-facing strings via `String(localized:)` (or SwiftUI's automatic catalog lookup) — never hardcode display text. This includes `String` values a view renders, such as labels and captions returned by view models.
- Every English key needs a translation in each shipped locale. Run `LocalizationTests` after touching any catalog.
- Xcode reserializes catalogs in its own canonical style, so after any programmatic edit run `swift scripts/normalize-xcstrings.swift` (no args = all catalogs; `--check` verifies) to avoid a large reordering diff.
- The catalog file map is in `KeeForge/Resources/README.md`.
- A new locale spans this repo and the website, and ships only when all of these are done:
  - All four catalogs are translated, with AutoFill keys matching the app's. `xcodegen generate` adds the locale to `knownRegions` from the catalogs.
  - `shippedTranslationLocales` in `LocalizationTests.swift` and every shipped-locale list in the docs name it (`git grep zh-Hant` finds them).
  - `docs/i18n/` has `README.<locale>.md` and `CONTRIBUTING.<locale>.md`, and the language switcher row in the root files and every translation links them.
  - The separate `keeforge.com` repo ships the locale in the same release, following the "Adding a locale" checklist in its README. That covers the pages, routing, Feedback Worker, and tests.
  - `CHANGELOG.md` notes the locale. App Store listing locales are a separate owner decision (`publish-app-store-version`).

## Code Review

- Review the current PR head, the full diff, and affected callers. On re-review, verify earlier findings in code and check for new regressions; recheck the head before posting or approving.
- Prioritize concrete correctness, data-loss, and security bugs. Trace save/sync/merge and authentication flows through cancellation, background locking, concurrent edits, partial failures, and recovery; include existing on-disk data from shipped versions.
- Check iPhone, iPad, Mac, and AutoFill parity where affected. Shared SwiftUI and passing unit tests do not establish native layout, keyboard/focus behavior, or usable recovery actions. Check localized copy against the actual behavior.
- Use focused tests or production-code reproductions for suspected bugs. Regression tests should fail on the broken behavior and exercise relevant persistence/cache effects, not mock them away. Check KDBX interoperability when format or save behavior changes.
- Report actionable findings by severity with a precise code location, trigger, user impact, and evidence. State the reviewed revision, validation performed, and remaining UI/device/hardware gaps; skipped tests and green CI do not prove untested behavior.
- When asked to post findings, use inline comments on the relevant code. Post reviews, approve, or resolve discussions only within the user's authorization.

## Build And Test

```bash
xcodegen generate

xcodebuild build -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'

xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet

xcodebuild test -project KeeForge.xcodeproj -scheme KeeForgeMac \
  -destination 'platform=macOS' \
  -only-testing:KeeForgeMacTests/DatabaseViewModelTests -quiet
```

- Run the smallest relevant slice, always with `-only-testing:`. Do not run the full UI suite unless explicitly asked.

### macOS tests

- Put Mac behavior in `@Observable` view models and test it in `KeeForgeTests/`, which also builds as `KeeForgeMacTests` and runs headless in CI. Code behind `#if os(macOS)` gets a `#if os(macOS)` test there.
- `KeeForgeMacUITests` never runs in CI. Use it only for interactions with no testable seam (keyboard routing, first responder, window lifecycle), and note why a unit test can't reach them. Layout changes get screenshot-audit captures, not assertions (`KeeForgeMacUITests/AGENTS.md`).

## Security Reminders

- **Keep [docs/threat-model.md](docs/threat-model.md) up to date.** Update it in the same change whenever architecture, data flows, protected assets, trust boundaries, security controls, assumptions, or limitations change; the full maintenance rules are in `docs/README.md`.
- Secrets are re-encrypted in memory with a per-session `SymmetricKey`; lock clears the session key and invalidates `EncryptedValue` access.
- Composite keys live in Keychain, not raw master passwords.
- Local saves compare the open-time SHA-512 before overwrite, create timestamped backups, and refresh the shared cached copy for AutoFill.
- App Group and security-scoped bookmark behavior affect both the app and AutoFill extension.
- Network egress stays limited to cloud sync, opt-in favicon fetching (DuckDuckGo, `icons.duckduckgo.com`), and the user-initiated feedback form (`feedback.keeforge.com`).
