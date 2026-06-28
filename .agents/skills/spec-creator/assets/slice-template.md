# Slice <NN>: <Title>

> Parent: [`epic.md`](./epic.md) · Depends on: <slices or "—">

## Goal

One sentence: what this slice delivers on its own.

## Scope

**In:** behavior-level bullets of what this slice does.
**Out:** what a reader might think this slice does but the next slice handles.

## Affected areas

Rough orientation, not exhaustive.

- New: …
- Modified: …

## KeeForge bits *(remove if not KeeForge)*

- **Targets:** which targets each new/changed file belongs to.
- **project.yml:** `No changes` or bullet list, then `xcodegen generate`.
- **Accessibility identifiers:** new + preserved (view slices only).

## Testing

Concrete scenarios, not "add tests".

- **Unit:** `<TestFile>.swift` — `test_<behavior>_<condition>` (what it asserts), …
  Run slice: `-only-testing:KeeForgeTests/<TestClass>`
- **Integration / UI:** only if needed; otherwise `N/A — <reason>`.
- **Manual:** 2–4 things a human should click through once.
- **Edge cases that apply:** locked DB, cancellation, offline, large input, background→foreground, …

## Exit criteria

- [ ] Unit tests above pass.
- [ ] Manual checks done.
- [ ] No force unwraps; secrets via `EncryptedValue`; heavy work off main.
- [ ] `xcodegen generate` if `project.yml` changed.
- [ ] CHANGELOG entry under `## Unreleased`.

## CHANGELOG entry

`- <one-line user-visible framing>`
