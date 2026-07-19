# AGENTS.md

Entry point for coding agents working on KeeForge. This file is intentionally brief; most useful guidance now lives in folder-local `README.md` files next to the code.

## Project Snapshot

- Native iOS KeePass manager for KDBX 4.x databases
- Swift 6, SwiftUI, iOS 18+, `@Observable`, strict concurrency
- XcodeGen build graph: edit `project.yml`, then regenerate `KeeForge.xcodeproj`
- Main targets: `KeeForge`, `KeeForgeAutoFill`, `KeeForgeTests`, `KeeForgeUITests`
- Current product areas: multi-database list, local and cloud-backed vaults, local edit/save groundwork, AutoFill, TOTP, passkeys, tip jar, screen protection

## Open The Local Doc First

- `KeeForge/README.md` — app-target map and cross-cutting flows
- `KeeForge/App/README.md` — app lifecycle, root navigation, scene handling
- `KeeForge/Models/README.md` — parser, writer, edit-draft, and core data-model guidance
- `KeeForge/Services/README.md` — storage, local save, cloud sync, keychain, bookmarks, device integrations
- `KeeForge/ViewModels/README.md` — list, unlock, save, search, sort, and TOTP state ownership
- `KeeForge/Views/README.md` — screen ownership and UI/testing conventions
- `AutoFillExtension/README.md` — extension constraints and shared-source notes
- `KeeForgeTests/README.md` — unit-test map and selection rules
- `KeeForgeUITests/README.md` — XCUITest workflow and flake-avoidance guidance
- `TestFixtures/README.md` — bundled databases, passwords, and key files
- `ci_scripts/README.md` — Xcode Cloud bootstrap behavior
- `docs/README.md` — archive of past design specs, audits, and notes (historical; not guaranteed to match current code)

## Agent Orchestration

If you are a very powerful model like Fable 5, feel free to delegate implementation and test to sub-agents with appropriate models. If you are Claude, feel free to use Codex CLI with a strong model (e.g., GPT 5.6 sol xhigh) for subagents' tasks, too. This is important to keep context windows manageable.

## Repo-Wide Rules

### Coding Styles

- Use `@Observable`, not `ObservableObject` / `@Published`.
- Use `NavigationStack` + `NavigationPath`, not `NavigationView`.
- Keep crypto, parsing, and secret handling off the main thread.
- Treat `KeeForge/Models/KDBXParser.swift`, `KeeForge/Models/KDBXWriter.swift`, `KeeForge/Models/KDBXCrypto.swift`, `KeeForge/Models/DatabaseDraft.swift`, `KeeForge/Models/Entry.swift`, `KeeForge/Models/Group.swift`, `KeeForge/Models/EncryptedValue.swift`, and `KeeForge/Models/TOTPGenerator.swift` as stable core. Change them only for real bugs or intentional format/security work, and add focused tests.
- No force unwraps outside tests.

### Workflows

- Put temporary agent artifacts such as handoff prompts, investigation notes, and scratch scripts under `scratch/`; it is gitignored and must not contain files intended to ship.
- If you add, remove, or retarget source files, update `project.yml` and run `xcodegen generate`.
- When adding new files, update the nearest folder-local `README.md` if the file changes that folder's map, ownership notes, or workflow guidance.
- Do not update `docs/specs` for new code changes unless explicitly asked. These specs are mostly historical artifacts, not living implementation docs.
- When changing code shared with `AutoFillExtension`, keep extension-safe imports/APIs and target membership in sync.
- When adding or changing database creation, edit operations, KDBX parser/writer behavior, protected fields, unknown XML handling, AutoFill save, cloud save, or local save, update `KeeForgeTests/KDBXCompatibilityTests.swift` and the compatibility artifact gate if the supported compatibility matrix changes.
- Preserve accessibility identifiers or update the relevant UI tests in the same change.
- Do not use MCP tools to run Xcode tests. Start a fresh `bash` session and run the test command there instead.
- Update `CHANGELOG.md` for feature or bug-fix commits. Add entries only under `## Unreleased`. It's okay to skip if the bug fix is for an unreleased feature.

### Localization

- UI text is localized with Xcode String Catalogs (`.xcstrings`), source language `en`. Currently shipped locales: `en`, `de`.
- Four catalogs: `Localizable.xcstrings` + `InfoPlist.xcstrings` under `KeeForge/Resources/`, mirrored under `AutoFillExtension/`. Reach user-facing strings via `String(localized:)` (or SwiftUI's automatic catalog lookup) — never hardcode display text.
- Every English key needs a translation in each shipped locale; `KeeForgeTests/LocalizationTests.swift` fails the build on missing or drifted translations. Run it after touching any catalog.
- When adding a new locale, also translate the user-facing docs: the `README.md` files, and the separate `keeforge.com` website repo (its content needs the same locale coverage).
- Xcode reserializes `.xcstrings` into its own canonical style on open/build, so editing a catalog as plain JSON causes a large reordering diff next time. After any programmatic catalog edit, run `swift scripts/normalize-xcstrings.swift` (no args = all catalogs; `--check` gates CI) so committed bytes match Xcode's.

### Research Notes

- When asked for reference implementations, consult `https://github.com/keepassium/keepassium` and `https://github.com/strongbox-password-safe/Strongbox`.

### Version Control Notes

- Prefer committing on the current branch, or on `main` if already there. Avoid creating new branches when possible, and push directly instead of waiting for a separate branch workflow.

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
- Local saves compare the open-time SHA-512 before overwrite, create timestamped backups, and refresh the shared cached copy for AutoFill.
- App Group and security-scoped bookmark behavior affect both the app and AutoFill extension.
- Network access should stay limited to explicit product features such as cloud sync and opt-in favicon fetching.
