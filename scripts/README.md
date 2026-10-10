# Scripts

Local developer tooling. Hand-run scripts live here; anything CI, Xcode Cloud, or XcodeGen invokes lives in `ci_scripts/` (see `ci_scripts/AGENTS.md`).

## Current Scripts

- `normalize-xcstrings.swift` — rewrites `.xcstrings` catalogs into Xcode's canonical serialization, so a programmatic edit does not turn into a large reordering diff on Xcode's next round trip. Run `swift scripts/normalize-xcstrings.swift` after any programmatic catalog edit: no args = all tracked catalogs, file args restrict the set, `--check` writes nothing and exits non-zero on drift (no CI job runs it). Swift on purpose: the key order depends on Foundation's `localizedStandardCompare`.
- `generate-merge-fixtures.sh` — regenerates the KeePass Synchronize merge oracle fixtures under `TestFixtures/Merge/` (see `TestFixtures/README.md`). Needs `python3` with `pykeepass` and KeePassXC's `keepassxc-cli` (`--keepassxc-cli PATH` overrides the default location); no Xcode and no repo lock. Slow on purpose: merge resolution is timestamp-driven at one-second granularity, so it sleeps between edits whose order decides the outcome. `--list` prints the scenario ids, `--scenario <id>` (repeatable) rebuilds a subset, `--output DIR` writes elsewhere.
- `with-repo-lock.sh` — repo-wide mutex for local Xcode builds, tests, simulator runs, and Mac app runs, shared by the main checkout and every linked worktree because the lock lives under the git common dir. Wrap a command with `with-repo-lock.sh xcode -- <cmd>`, or hold it across steps with `acquire`/`release`; `--status` shows the holder. Locks whose holder died are reclaimed automatically. Options and exit codes (73 = lock path unusable, 75 = timed out) are in the script header.
- `test_with_repo_lock.sh` — offline regression test for the lock wrapper.

## Guidance

- Keep scripts runnable from the repo root with no setup beyond standard dev tooling (`swift`, `xcrun`, `jq`).
- If a script must run in CI or Xcode Cloud, move it into `ci_scripts/`.
