# Product And Design Docs

Open this folder when the code alone is not enough and you need the longer-form design or security context behind a feature.

## Good Starting Points

- `competitive-gap-analysis.md` — quick comparison against Strongbox and KeePassium, plus the largest current product gaps.
- `specs/cloud-file-autofill.md` — AutoFill behavior for cloud-hosted databases.
- `specs/cloud-sync.md` and `specs/multi-database.md` — database list, cloud-backed databases, and sync behavior.
- `specs/edit-support/epic.md` plus `specs/edit-support/01-xml-round-trip.md` through `07-autofill-save.md` — staged write-path design for XML round-trip, KDBX writing, draft/save flow, and pending cloud/UI/AutoFill work.
- `specs/favicon.md` — website icon fetching and caching.
- `specs/key-file.md` — supported key-file formats and implementation notes.
- `specs/passkey.md` — passkey storage and signing behavior.
- `specs/totp-autofill.md` — TOTP-related implementation direction.
- `audits/2026-02-26-security-audit-claude.md` and `audits/2026-03-03-security-audit-codex.md` — security review context and follow-up items.
- `privacy-policy.md` — user-facing privacy guarantees that code changes should not contradict.

## Guidance

- Treat these docs as intent and spec context, not guaranteed truth. Confirm against current code before changing behavior.
- If a code change supersedes one of these documents, update the doc or leave a note so future agents do not chase stale assumptions.
- The edit-support specs are staged by slice; some later slices describe planned work rather than shipped behavior, so confirm against the current code before implementing them.
