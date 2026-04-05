# AGENTS.md

Entry point for coding agents working on KeeForge. This file is intentionally brief; most useful guidance now lives in folder-local `README.md` files next to the code.

## Project Snapshot

- Native iOS KeePass manager for KDBX 4.x databases
- Swift 6, SwiftUI, iOS 17+, `@Observable`, strict concurrency
- XcodeGen build graph: edit `project.yml`, then regenerate `KeeForge.xcodeproj`
- Main targets: `KeeForge`, `AutoFillExtension`, `KeeForgeTests`, `KeeForgeUITests`
- Current product areas: multi-database list, local and cloud-backed vaults, AutoFill, TOTP, passkeys, tip jar, screen protection

## Open The Local Doc First

- `KeeForge/README.md` — app-target map and cross-cutting flows
- `KeeForge/App/README.md` — app lifecycle, root navigation, scene handling
- `KeeForge/Models/README.md` — parser, crypto, and core data-model guidance
- `KeeForge/Services/README.md` — storage, cloud sync, keychain, bookmarks, device integrations
- `KeeForge/ViewModels/README.md` — list, unlock, search, sort, and TOTP state ownership
- `KeeForge/Views/README.md` — screen ownership and UI/testing conventions
- `AutoFillExtension/README.md` — extension constraints and shared-source notes
- `KeeForgeTests/README.md` — unit-test map and selection rules
- `KeeForgeUITests/README.md` — XCUITest workflow and flake-avoidance guidance
- `TestFixtures/README.md` — bundled databases, passwords, and key files
- `ci_scripts/README.md` — Xcode Cloud bootstrap behavior
- `docs/README.md` — long-form specs, audits, and implementation notes

## Repo-Wide Rules

- Use `@Observable`, not `ObservableObject` / `@Published`.
- Use `NavigationStack` + `NavigationPath`, not `NavigationView`.
- Keep crypto, parsing, and secret handling off the main thread.
- Treat `KeeForge/Models/KDBXParser.swift`, `KeeForge/Models/KDBXCrypto.swift`, `KeeForge/Models/Entry.swift`, `KeeForge/Models/Group.swift`, `KeeForge/Models/EncryptedValue.swift`, and `KeeForge/Models/TOTPGenerator.swift` as stable core. Change them only for real bugs or intentional format/security work, and add focused tests.
- No force unwraps outside tests.
- If you add, remove, or retarget source files, update `project.yml` and run `xcodegen generate`.
- When changing code shared with `AutoFillExtension`, keep extension-safe imports/APIs and target membership in sync.
- Preserve accessibility identifiers or update the relevant UI tests in the same change.
- Update `CHANGELOG.md` for feature or bug-fix commits. Add entries only under `## Unreleased`. It's okay to skip if the bug fix is for an unreleased feature.

## Build And Test

```bash
xcodegen generate

xcodebuild build -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:KeeForgeTests/DatabaseViewModelTests -quiet
```

- Always prefer the smallest relevant test slice.
- Always use `-only-testing:`.
- Do not run the full UI suite unless explicitly asked.
- If Xcode reports stale project references after file moves, regenerate with `xcodegen generate`.

## Security Reminders

- Secrets are re-encrypted in memory with a per-session `SymmetricKey`; lock clears the session key and invalidates `EncryptedValue` access.
- Composite keys live in Keychain, not raw master passwords.
- App Group and security-scoped bookmark behavior affect both the app and AutoFill extension.
- Network access should stay limited to explicit product features such as cloud sync and opt-in favicon fetching.
