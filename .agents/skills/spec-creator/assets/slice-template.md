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

- **Unit:** `<TestFile>.swift` — named scenarios: <behavior> under <condition> (what each asserts), …
  Leave exact test method names to the implementing agent.
  Run slice: `-only-testing:KeeForgeTests/<TestClass>`
- **Integration / UI:** only if needed; otherwise `N/A — <reason>`.
- **Manual:** 2–4 things a human should click through once.
- **Edge cases that apply:** cancellation, offline, large input, background→foreground, locked DB *(KeeForge)*, …

## Exit criteria

- [ ] Unit tests above pass.
- [ ] Manual checks done.
- [ ] CHANGELOG entry written, or explicitly deferred to the epic's entry.
- [ ] *(KeeForge)* No force unwraps; secrets via `EncryptedValue`; heavy work off main.
- [ ] *(KeeForge)* `xcodegen generate` if `project.yml` changed.

## CHANGELOG entry

`- <one-line user-visible framing>`

Or, for a groundwork slice with no user-visible behavior of its own:
`N/A — covered by the epic's entry, lands with slice <NN>.` The epic owns the final
user-facing entry when slices defer.
