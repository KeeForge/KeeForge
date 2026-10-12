# AGENTS.md

Entry point for coding agents working on KeeForge. This file holds the repo-wide rules. Each folder's `AGENTS.md` holds that folder's invariants, ownership boundaries, and test mapping.

## High level guidance

- Do not preserve backward compatibility unless required by the existing install base. Remove obsolete paths instead of adding compatibility layers, fallbacks, or migrations.
- Choose the simplest implementation that fully meets the current requirements. Avoid speculative abstractions, configuration, and indirection.
- Grow the system in layers. Start from the smallest version that works end to end, and add each new capability on top of a product that already works. Never trade a working product for unfinished complexity.
- Keep components modular and concerns clearly separated.
- Prefer established, well-maintained libraries when they reduce overall complexity or improve reliability. Do not reimplement common functionality without a clear reason.
- Lean on the dependencies already in the project before writing your own implementation or adding packages. Do not assume a library lacks a capability without checking its documentation and types.
- Make architectural decisions for the long term. Do not accept a stopgap that only works for now and is meant to be replaced later.

## Project Snapshot

- Native iPhone, iPad, and Mac KeePass manager for KDBX 4.x; also reads KDBX 3.1 (read-only)
- Swift 6, SwiftUI, iOS 18+ / macOS 15+, `@Observable`, strict concurrency
- XcodeGen build graph: edit `project.yml`, then regenerate `KeeForge.xcodeproj`; target-membership rules live in `KeeForge/AGENTS.md`
- Xcode Cloud runs the `KeeForgeCloudUnitTests`, `KeeForgeCloudUIA`, and `KeeForgeCloudUIB` schemes; the partition rules are in `ci_scripts/AGENTS.md`.
- Main targets: `KeeForge`, `KeeForgeMac`, `KeeForgeAutoFill`, `KeeForgeMacAutoFill`, `KeeForgeTests`, `KeeForgeMacTests`, `KeeForgeUITests`, `KeeForgeMacUITests`

## Find The Right Doc

Before changing a folder, read its `AGENTS.md` and each parent's `AGENTS.md` up to this file. These docs are not on that path:

- `docs/threat-model.md`: living threat model; required review for major product or architecture changes
- `docs/README.md`: doc index and maintenance rules (specs, audits, and notes are historical)
- `KeeForgeMac/README.md`: Mac target constraints, distribution channels
- `KeeForgeMac/SECURITY.md`: Mac security boundaries and platform limits
- `TestFixtures/README.md`: bundled databases, passwords, key files
- `KeeForge/Resources/README.md`: string catalogs, assets, add-a-locale checklist
- `.github/AGENTS.md`: CI workflow gating map (not a README, which GitHub would render as the repo front page)
- `ci_scripts/AGENTS.md`: Xcode Cloud bootstrap and `run_kdbx_compatibility_gate.sh`, the required KDBX compatibility gate
- `scripts/README.md`: local dev tooling
- `Vendor/KeeForgeTwofish/README.md`: vendored Twofish package

Repository skills are in `.agents/skills/`: `prepare-release`, `respin-release`, `ship-release`, `pre-release-review`, `publish-app-store-version`, `test-audit`, `triage-feedback`, `keeforge-swiftui`, `keeforge-github-issues`.

## Repo-Wide Rules

### Coding Styles

- Use `@Observable`, not `ObservableObject` / `@Published`.
- Use `NavigationStack` with typed routes, not `NavigationView`. Keep SwiftUI navigation objects out of shared view models.
- Keep crypto, parsing, and secret handling off the main thread.
- Treat these `KeeForge/Models/` files as stable core: `KDBXParser.swift`, `KDBX3Parser.swift`, `KDBXWriter.swift`, `KDBXXMLSerializer.swift`, `KDBXCrypto.swift`, `KDBXOuterCipher.swift`, `OpaqueXMLNodes.swift`, `DatabaseDraft.swift`, `EntryEdit.swift`, `Entry.swift`, `Group.swift`, `EncryptedValue.swift`, `TOTPGenerator.swift`. Change them only for real bugs or intentional format/security work, and add focused tests.
- No force unwraps outside tests.
- Keep comments minimal. A comment is only warranted when the code cannot explain itself — a non-obvious constraint, a format/platform quirk, or the reason behind a surprising choice. Don't restate what the code already says, don't narrate control flow, and don't leave changelog-style notes ("was X, now Y") or review/audit chatter in the source; that belongs in the commit message. Prefer one short line over a paragraph.

### Workflows

- Keep temporary agent artifacts in the main checkout's gitignored `scratch/`, never a linked worktree's. Find the main checkout with the first entry in `git worktree list --porcelain`.
- `scratch/` may be emptied at any time. Release artifacts and evidence a later step needs go in the main checkout's `build/releases/` (`ci_scripts/release_dir.sh`; layout in `.agents/skills/prepare-release/references/shared.md`).
- Update the folder's `AGENTS.md` when an invariant, ownership boundary, or test mapping changes. Do not add file maps, identifier lists, or history. Leave historical `docs/specs` alone unless explicitly asked.
- Preserve accessibility identifiers or update the relevant UI tests in the same change. `KeeForgeUITests` and `KeeForgeMacUITests` share one identifier surface, so update both.
- Add concise, user-facing changes to `CHANGELOG.md` under `## Unreleased`; fixes for unreleased features may skip it.

### Localization

- UI text uses Xcode String Catalogs (`.xcstrings`), source language `en`. Shipped locales: `en`, `de`, `fr`, `es`, `zh-Hans`, `zh-Hant`, `ja`, `it`, `ru`.
- Reach user-facing strings via `String(localized:)` (or SwiftUI's automatic catalog lookup) — never hardcode display text.
- Every English key needs a translation in each shipped locale. Run `KeeForgeTests/LocalizationTests.swift` (it also runs in `KeeForgeMacTests`) after touching any catalog.
- Xcode reserializes catalogs in its own canonical style, so after any programmatic edit run `swift scripts/normalize-xcstrings.swift` (no args = all catalogs; `--check` verifies) to avoid a large reordering diff.
- The catalog file map and add-a-locale checklist are in `KeeForge/Resources/README.md`.

### Research Notes

- When asked for reference implementations, consult `https://github.com/keepassium/keepassium` and `https://github.com/strongbox-password-safe/Strongbox`.

### Version Control Notes

- Every commit must be DCO signed off (`git commit -s`); the "DCO" status check is required.

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

- Always prefer the smallest relevant test slice.
- Always use `-only-testing:`.
- Do not run the full UI suite unless explicitly asked.
- `KeeForgeMacTests` compiles the `KeeForgeTests` folder; there is no `KeeForgeMacTests` directory.
- The RC workflow (`.github/workflows/ios18-rc-tests.yml`) tests on an iOS 18 iPhone SE (3rd generation) simulator — reproduce RC failures there.

### macOS Test Strategy

Mac XCUITest is the slowest, most fragile lever: it needs an unlocked login session, takes real screen and input focus, and serializes against every other Xcode run. Reach for it last. Put Mac behavior in `@Observable` view models and cover it in `KeeForgeMacTests`, which runs headless on the shared `KeeForgeTests` sources; keep `KeeForgeMacUITests` a thin smoke layer.

Find your change's row and write what it names before calling the change done:

| Change | Must exist when done |
| --- | --- |
| View model, service, or model behavior reachable on macOS | A `KeeForgeTests/` test; it compiles into `KeeForgeMacTests` for free. The default answer. |
| Behavior behind `#if os(macOS)` | A `#if os(macOS)` test in `KeeForgeTests/`, like `MacLockMonitorTests` and `CredentialProviderShellMacTests`. |
| Mac-only interaction with no view-model seam (keyboard routing, first responder, window lifecycle) | Give it a seam and test that. Otherwise the smallest case in `KeeForgeMacUITests/MacSmokeUITests.swift`, noting why a unit test cannot reach it (`MacUnlockPasswordFieldTests` is the model). |
| Layout or visual polish | No new assertions. Use previews or the `MacScreenshotAuditUITests` captures; add a screen to that walk for a new screen. |
| A SwiftUI view the macOS AutoFill shell hosts | A manual pass in a real AutoFill panel; it has no `NSToolbar` (`AutoFillExtension/AGENTS.md`). |
| Parser, writer, protected fields, unknown XML, or a save path | `KDBXCompatibilityTests` (rule in `KeeForge/AGENTS.md`) plus `KDBX_COMPAT_SCHEME=KeeForgeMac ci_scripts/run_kdbx_compatibility_gate.sh`. |
| A write to the system credential identity store | A `CredentialIdentityStoreManagerTests` case with `FakeCredentialIdentityStore.supportsIncrementalUpdatesValue = false`, beside the incremental one; macOS takes that branch on releases that report no incremental updates. |
| Entitlements, App Group container, extension boundary, or Sparkle | Refresh `KeeForgeMac/SECURITY.md`; re-run `AppGroupGuardrailTests` if the container's write surface moved. |

- Shared SwiftUI is the default. A targeted AppKit view is right only where SwiftUI cannot express the interaction (`MacUnlockPasswordField`: secure event input bypasses SwiftUI key handling). Take that escape hatch deliberately, not to work around a flaky test.
- `KeeForgeMacUITests` never runs in CI (`.github/AGENTS.md`), so behavior covered only there is uncovered for CI.
- Every `KeeForgeTests/` test runs on both platforms. Keep macOS-only cases behind `#if os(macOS)`, not branched inside a shared test.

## Security Reminders

- **Keep [docs/threat-model.md](docs/threat-model.md) up to date.** It is a living document, exempt from archive rules. Review it for every major product or architecture change and update it in the same change whenever architecture, data flows, protected assets, trust boundaries, security controls, assumptions, or limitations change. Keep its source references accurate; maintenance requirements are detailed in `docs/README.md`.
- Secrets are re-encrypted in memory with a per-session `SymmetricKey`; lock clears the session key and invalidates `EncryptedValue` access.
- Composite keys live in Keychain, not raw master passwords.
- Local saves compare the open-time SHA-512 before overwrite, create timestamped backups, and refresh the shared cached copy for AutoFill.
- App Group and security-scoped bookmark behavior affect both the app and AutoFill extension.
- Network egress stays limited to cloud sync, opt-in favicon fetching (DuckDuckGo, `icons.duckduckgo.com`), and the user-initiated feedback form (`feedback.keeforge.com`).
