# Product And Design Docs

Open this folder when the code alone is not enough and you need the longer-form design or security context behind a feature.

## Good Starting Points

- `competitive-gap-analysis.md` — quick comparison against Strongbox and KeePassium, plus the largest current product gaps.
- `specs/cloud-file-autofill.md` — AutoFill behavior for cloud-hosted databases.
- `specs/cloud-sync.md` and `specs/multi-database.md` — database list, cloud-backed databases, and sync behavior.
- `specs/database-creation.md` — plan for creating brand-new local KDBX 4.x databases in KeeForge.
- `specs/edit-support/epic.md` plus `specs/edit-support/01-xml-round-trip.md` through `07-autofill-save.md` — staged write-path design for XML round-trip, KDBX writing, draft/save flow, and pending cloud/UI/AutoFill work.
- `specs/favicon.md` — website icon fetching and caching.
- `specs/key-file.md` — supported key-file formats and implementation notes.
- `specs/macos-port/epic.md` plus `specs/macos-port/01-macos-target-scaffolding.md` through `07-distribution.md` — staged plan for the native macOS app (SwiftUI multiplatform target, Mac UX, desktop cloud OAuth, macOS AutoFill, security polish, MAS + Developer ID distribution). Planned work, not shipped behavior.
- `specs/passkey.md` — passkey storage and signing behavior.
- `specs/totp-autofill.md` — TOTP-related implementation direction.
- `webdav-manual-e2e-checklist.md` — pre-release manual verification pass for WebDAV sync against real servers.
- `audits/2026-02-26-security-audit-claude.md` and `audits/2026-03-03-security-audit-codex.md` — security review context and follow-up items.
- The user-facing privacy policy lives at <https://keeforge.com/privacy> (source in the `keeforge.com` repo). Code changes should not contradict it.

## Guidance

- Treat these docs as intent and spec context, not guaranteed truth. Confirm against current code before changing behavior.
- The current app uses an adaptive navigation shell: compact layouts move into a full-screen vault flow, and regular-width layouts keep the database list visible beside the selected vault. Older specs may still describe the previous sheet-based flow.
- If a code change supersedes one of these documents, update the doc or leave a note so future agents do not chase stale assumptions.
- The edit-support specs are staged by slice; some later slices describe planned work rather than shipped behavior, so confirm against the current code before implementing them.
