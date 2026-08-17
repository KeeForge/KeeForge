# Docs Archive

**This folder is an archive of past design and review documents.** Each doc captures the design that guided an implementation or audit at the time it was written. None of them are maintained afterward, and there is **no guarantee that they describe current code behavior** — features may have shipped differently, been reworked, or not been built at all. Always confirm against the current code (and folder-local `README.md` files next to the code) before relying on anything here.

Files and folders are prefixed with the date the doc was written. Do not update these docs for new code changes unless explicitly asked.

Two root items have no date prefix and are not archive material: `i18n/` and `macos-security-notes.md`. The user-facing privacy policy lives at <https://keeforge.com/privacy> (source in the `keeforge.com` repo); code changes should not contradict it.

`i18n/` is **living**: it holds the translated `README.<locale>.md` and `CONTRIBUTING.<locale>.md` files for every shipped locale. Update them whenever the root `README.md` or `CONTRIBUTING.md` changes, and keep their relative links pointing at repo-root paths through `../../`.

`macos-security-notes.md` is a **living** note on the macOS app's per-platform security deltas (in-memory model, App Group world-readability, screen-capture best-effort, clipboard ceiling, attachment previews, what is not fixable at the app level). Keep it truthful alongside the code; it backs the README security highlights and the in-app Settings copy.

## `specs/` — Feature Design Specs

Design docs written before or during a feature's implementation. Multi-slice features live in a dated folder with an `epic.md` overview plus numbered slice docs.

| Date | Spec | Topic |
|---|---|---|
| 2026-02-25 | `specs/2026-02-25-favicon.md` | Website icon fetching and caching |
| 2026-03-07 | `specs/2026-03-07-key-file.md` | Key-file formats and handling |
| 2026-03-07 | `specs/2026-03-07-passkey.md` | Passkey storage and signing |
| 2026-03-08 | `specs/2026-03-08-cloud-file-autofill.md` | AutoFill for cloud-hosted databases |
| 2026-03-29 | `specs/2026-03-29-multi-database.md` | Multi-database list |
| 2026-03-29 | `specs/2026-03-29-totp-autofill.md` | TOTP in AutoFill |
| 2026-04-03 | `specs/2026-04-03-cloud-sync.md` | Cloud-backed databases and sync |
| 2026-04-07 | `specs/2026-04-07-edit-support/` | Write path: XML round-trip, KDBX writer, drafts, local/cloud/AutoFill save (epic + slices 01–07) |
| 2026-04-15 | `specs/2026-04-15-kdbx-3-compatibility.md` | KDBX 3.x compatibility |
| 2026-04-24 | `specs/2026-04-24-database-creation.md` | Creating new local KDBX 4.x databases |
| 2026-07-12 | `specs/2026-07-12-macos-port/` | Native macOS app: target scaffolding, Mac UX, desktop OAuth, macOS AutoFill, distribution (epic + slices 01–07) |
| 2026-07-12 | `specs/2026-07-12-twofish-support/` | Twofish cipher support and KDBX 3.1 read (epic + slices 01–03) |
| 2026-07-19 | `specs/2026-07-19-selectable-autofill-per-database/` | Per-database AutoFill selection, multi-database QuickType, clear-entries action (epic + slices 01–06; `deferred-tests.md` is the 2026-07-19 pick-up list for the tests written after the Linux implementation — all slice tests are done, and the remaining manual checks were largely automated by `AutoFillStoreUITests`, see `KeeForgeUITests/README.md`) |
| 2026-07-19 | `specs/2026-07-19-tag-integration/` | Tag browser, tag search, group-tag inheritance, editor tag suggestions (epic + slices 01–04) |
| 2026-07-20 | `specs/2026-07-20-autofill-store-validation-harness/` | Opt-in real-`ASCredentialIdentityStore` assertion harness: debug inspector screen, simulator provisioning, lifecycle UI tests (epic + slices 01–03) |
| 2026-07-26 | `specs/2026-07-26-kdbx-format-hardening/` | ChaCha20 implementation consolidation + unknown KDBX4 inner-header preservation (epic + slices 01–02; from the 2026-07-25 test-suite audit) |

## `audits/` — Security Audits

Point-in-time security reviews; findings may have been fixed (or new issues introduced) since.

| Date | Audit |
|---|---|
| 2026-02-26 | `audits/2026-02-26-security-audit-claude.md` |
| 2026-03-03 | `audits/2026-03-03-security-audit-codex.md` |
| 2026-07-25 | `audits/2026-07-25-test-suite-audit.md` — full test-suite audit (unit/UI/KDBX-compat/CI); records implemented fixes and deliberately-deferred recommendations |
| 2026-08-01 | `audits/2026-08-01-security-audit.md` — repository-wide threat model, static review methodology, six consolidated findings, and verified remediation; mirrored at <https://keeforge.com/security-audit/> (this file is the source of record) |

## `analysis/` — Product Analysis

| Date | Doc | Topic |
|---|---|---|
| 2026-04-18 | `analysis/2026-04-18-competitive-gap-analysis.md` | Comparison against Strongbox and KeePassium; product gaps as of that date |

## `checklists/` — Manual Test Checklists

| Date | Doc | Topic |
|---|---|---|
| 2026-07-04 | `checklists/2026-07-04-webdav-manual-e2e-checklist.md` | Manual WebDAV sync verification against real servers |
| 2026-08-17 | `checklists/2026-08-17-ios-27-readiness-checklist.md` | iOS 27 / Xcode 27 readiness audit and preparation checklist (against beta 5) |

## Adding A New Doc

- Put it in the matching category folder and prefix the file (or the folder, for multi-file specs) with the date written: `YYYY-MM-DD-<kebab-case-name>`.
- Add a row to the table above.
- Remember the doc becomes archive material the moment the work ships; keep living guidance in the folder-local `README.md` files next to the code instead.
