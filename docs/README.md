# Product And Design Docs

Open this folder when the code alone is not enough and you need the longer-form design or security context behind a feature.

## Good Starting Points

- `CLOUD_SYNC_SPEC.md` and `MULTI_DATABASE_SPEC.md` — database list, cloud-backed databases, and sync behavior.
- `specs/edit-support/epic.md` plus `specs/edit-support/01-xml-round-trip.md` through `07-autofill-save.md` — staged write-path design for XML round-trip, KDBX writing, draft/save flow, and pending cloud/UI/AutoFill work.
- `CLOUD_FILE_AUTOFILL_RESEARCH.md` — AutoFill behavior for cloud-hosted databases.
- `KEY_FILE_IMPLEMENTATION.md` — supported key-file formats and implementation notes.
- `PASSKEY_IMPLEMENTATION.md` — passkey storage and signing behavior.
- `TOTP_AUTOFILL_PLAN.md` — TOTP-related implementation direction.
- `favicon-spec.md` — website icon fetching and caching.
- `SECURITY_AUDIT.md` and `SECURITY_AUDIT_CODEX.md` — security review context and follow-up items.
- `privacy-policy.md` — user-facing privacy guarantees that code changes should not contradict.

## Guidance

- Treat these docs as intent and spec context, not guaranteed truth. Confirm against current code before changing behavior.
- If a code change supersedes one of these documents, update the doc or leave a note so future agents do not chase stale assumptions.
- The edit-support specs are staged by slice; some later slices describe planned work rather than shipped behavior, so confirm against the current code before implementing them.
