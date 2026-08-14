# Scripts

Local developer tooling. Folder rule: hand-run scripts live here; anything CI or Xcode Cloud invokes lives in `ci_scripts/` (see `ci_scripts/README.md`).

## Current Scripts

- `normalize-xcstrings.swift` — rewrites `.xcstrings` catalogs into Xcode's canonical serialization (space-padded ` : `, `localizedStandardCompare` key order, expanded empty objects, no trailing newline); without it a plain-JSON edit produces a large reordering diff on Xcode's next round trip. Run `swift scripts/normalize-xcstrings.swift` after any programmatic catalog edit (per `AGENTS.md`): no args = all tracked catalogs, file args restrict the set, `--check` writes nothing and exits non-zero on drift (no CI job runs it). Swift on purpose — the key order depends on Foundation's `localizedStandardCompare`.
- `generate-merge-fixtures.sh` — regenerates the KeePass Synchronize merge oracle fixtures under `TestFixtures/Merge/` (see `TestFixtures/README.md`). Builds one deterministic base database with `pykeepass` (KDBX 4.0 — `keepassxc-cli db-create` only writes KDBX 3.1, and KeeForge's writer is KDBX 4 only), then drives every divergence through `keepassxc-cli` and records the reference with `keepassxc-cli merge -s`. Needs `python3` with `pykeepass` and KeePassXC's `keepassxc-cli` (`--keepassxc-cli PATH` overrides the default `/Applications/KeePassXC.app/…`). Slow on purpose: KDBX timestamps have one-second granularity and merge resolution is timestamp-driven, so the script sleeps between edits whose ordering decides the outcome. `--list` prints the scenario ids, `--scenario <id>` (repeatable) rebuilds a subset, `--output DIR` writes elsewhere. Needs no Xcode and no repo lock.
- `with-repo-lock.sh` — repo-wide, cross-worktree mutex for local Xcode work. Serializes builds, unit/UI tests, iOS Simulator runs, and macOS app tests so parallel agent sessions (main checkout plus every `.claude/worktrees/*`) never contend for the toolchain, the simulators, or the screen. Wrap a command with `with-repo-lock.sh xcode -- <cmd>`, or hold it across several steps with `acquire`/`release`; `--status` shows the holder. The lock directory lives under the shared git common dir (`git rev-parse --git-common-dir` → `.git/keeforge-locks/`), which is what makes it global across linked worktrees; locks whose holder process died are reclaimed automatically. Usage and exit codes (75 = timed out waiting) are in the script header; the agent-facing policy is in `CLAUDE.local.md`.

## Guidance

- Keep scripts runnable from the repo root with no setup beyond standard dev tooling (`swift`, `xcrun`, `jq`).
- If a script must run in CI or Xcode Cloud, move or duplicate it into `ci_scripts/`.
