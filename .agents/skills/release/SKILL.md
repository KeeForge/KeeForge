---
name: release
description: >
  Run the KeeForge iOS release process: cut a release/{major}.{minor} branch, build release
  candidates onto the public TestFlight channel, soak them, and ship the exact soaked build to
  the App Store. Bumps versions and build numbers in project.yml, updates CHANGELOG.md and the
  What's New sheet, runs the local KDBX compatibility gate, and pushes rc/{version}-b{build}
  tags so Xcode Cloud and the iOS 18 GitHub Actions workflow test and archive each candidate.
  Use this skill whenever the user wants to cut a release, start a release branch, respin a
  release candidate, ship a soaked build, bump the version, or prepare a build for
  TestFlight/App Store. Triggers on phrases like "release", "new version", "bump version",
  "cut a release", "prepare release", "ship it", "release candidate", "respin", "new RC build",
  "hotfix", or "push a new build".
---

# KeeForge Release Workflow

Releases run on a dedicated `release/{major}.{minor}` branch, reach users through the public
TestFlight channel first, and ship the **exact binary that was soaked**. This is a sequential,
high-stakes workflow: each step depends on the previous one succeeding. Do not skip steps or
proceed past a failure.

Test execution model: the full unit and UI suites run on **Xcode Cloud** and **GitHub Actions**.
Do not run them locally up front. Run focused local XCTest reproductions only when a cloud test
fails — see `gate-adjudication.md`.

## The four invariants

Violating any of these invalidates the release. They outrank convenience at every step, and
unlike the soak targets in A10 they are not judgement calls.

1. **Ship the binary you soaked.** The App Store build is selected from TestFlight, never
   re-archived. `v{version}` is a record of what shipped, not a build trigger.
2. **Every candidate gets its own build number and its own `rc/` tag.** Bump
   `CURRENT_PROJECT_VERSION` for each one so candidates are never confused with each other. Note
   that Xcode Cloud overrides this number on the binary it uploads (see A9), so the uniqueness App
   Store Connect actually enforces is Xcode Cloud's, not yours — but a stale build number in the
   repo makes every later step ambiguous about which candidate is which.
3. **Both CI gates are accepted before a build reaches external testers.** Green, or every
   failure adjudicated per `gate-adjudication.md`. The soak window is flexible; this is not.
4. **Tags are immutable.** Never delete, move, or force-push a tag. Every `rc/*` tag is a
   permanent record of one candidate build.

## Pick the mode first

Identify which mode applies before touching anything. Ask the user if it is ambiguous.

| Situation | Mode |
| --- | --- |
| Starting a new minor/major version, no branch yet | **A — Cut** |
| Release branch exists, a fix needs a new candidate build | **B — Respin** |
| Soak criteria met, ready for the App Store | **C — Ship** |
| Shipped version needs a patch (`1.11.1`) | **D — Patch** |

Reference files, read on demand:

- `gate-adjudication.md` — how to read the two CI gates and adjudicate test failures locally.
  Read this whenever a gate is not green in A8. Gates are adjudicated there and nowhere else.
- `xcode-cloud-setup.md` — the one-time App Store Connect workflow configuration this process
  depends on. Read it if archives or TestFlight uploads are not appearing as expected.

---

# Mode A — Cut a release branch

## A1. Validate repo state and version

1. Verify the git state is releasable:
   - On `main` (`git branch --show-current`).
   - Clean working tree (`git status --porcelain` is empty).
   - Up to date: `git fetch origin --tags`, then confirm `main` is not behind `origin/main`.
2. Read `project.yml` and extract the current `MARKETING_VERSION` from the `KeeForge` target.
3. Run `git tag --list 'v*'`, `git tag --list 'rc/*'`, and `git branch -r --list 'origin/release/*'`.
4. Verify:
   - `v{version}` does not already exist.
   - `{version}` is valid semver (MAJOR.MINOR.PATCH) and greater than the current `MARKETING_VERSION`.
   - `release/{major}.{minor}` does not already exist. **If it does, this is Mode B or D, not Mode A.**
5. If a version was not supplied, suggest the next minor bump and ask the user to confirm.

## A2. Update CHANGELOG.md

1. Read `CHANGELOG.md`.
2. Find `## Unreleased` and collect all entries beneath it (up to the next `## v` heading).
   Entries may be flat bullets, already grouped under `###` subsections, or a mix.
3. If the Unreleased section is empty, warn the user and ask whether to proceed.
4. Organize the entries into categorized subsections. Keep entries already under a matching
   subsection where they are; classify each remaining bullet:
   - **New Features** — new user-facing capabilities
   - **Fixes** — bug fixes
   - **Security** — security-related changes
   - **Known Issues** — known problems or limitations
   - **Changes** — refactors, renames, internal improvements, infrastructure, test changes

   Only include subsections that have entries. Keep the original wording of each bullet.
5. Replace the Unreleased entries with the new versioned section:

```markdown
## Unreleased

## v{version} ({YYYY-MM-DD})

### New Features
- ...

### Fixes
- ...
```

The `## Unreleased` heading stays; its content moves into the new version section. Use today's
date from `date +%F` — do not guess. If the soak runs past that date, correct it in Mode C.

## A3. Review and fix What's New content

Perform this review for every release, even if the content already looks complete.

1. Review the new version's `### New Features` and `### Fixes` bullets as source material. Keep
   the sheet to at most three items: prioritize the most important user-facing features, then use
   remaining slots for notable bug fixes. A fix is notable when it materially improves a common
   workflow, prevents a crash or data-loss risk, or delivers a broad reliability improvement.
   Exclude routine polish, security hardening, known issues, and internal changes. If there are no
   eligible items, confirm `WhatsNewCatalog` has no case for this version and continue without an
   empty sheet. Confirm the proposal with the user before proceeding.
2. Inspect the matching version case in
   `KeeForge/Services/AppSupport/WhatsNewPresentationService.swift`. Add it if needed, or fix it
   when stale, incomplete, overly technical, or inaccurate.
3. Rewrite each included feature as short, benefit-led copy for ordinary users. Do not copy issue
   numbers, implementation details, test coverage, internal terminology, or raw changelog prose.
4. Check platform accuracy. Keep features available on both iOS and macOS shared; set the
   `platforms` argument for single-platform features. Never advertise an iOS-only feature in the
   Mac sheet or vice versa.
5. Add or update every affected key and its translations for every shipped locale (see AGENTS.md's
   Localization section; `KeeForgeTests/LocalizationTests.swift` is the source of truth) in
   `KeeForge/Resources/Localizable.xcstrings`. The localization tests in the RC run are the gate.
6. Re-read the completed sheet as a user. Fix unclear titles, repetitive descriptions, missing
   major features, or claims the release does not support.

## A4. Commit the release content to main, then cut the branch

Everything decided **once** for this release lands on `main` before the cut; only what varies
**per candidate** waits for the branch. A2, A3, and the marketing version are all in the first
group — they describe work already merged to `main`, and the changelog heading already commits to
the version number, so holding the matching `MARKETING_VERSION` back buys nothing.

Set `MARKETING_VERSION` to the new version string (e.g. `"1.11.0"`) on **all four** product
targets in `project.yml` — `KeeForge`, `KeeForgeAutoFill`, `KeeForgeMac`, and `KeeForgeMacAutoFill`.
The Mac targets ship in lockstep with iOS (same version, same build number), so there are exactly 4
values to update. Leave `CURRENT_PROJECT_VERSION` alone — that is A5's, and it changes with every
candidate.

```bash
xcodegen generate
git add CHANGELOG.md project.yml KeeForge.xcodeproj \
  KeeForge/Services/AppSupport/WhatsNewPresentationService.swift \
  KeeForge/Resources/Localizable.xcstrings
git commit -s -m "Prepare v{version}"
git push origin main
```

`main` now builds as `{version}`, so local dev builds will show the new What's New sheet once —
`WhatsNewCatalog` is keyed by version string and the marketing version now matches it. That is
harmless and self-limiting: `WhatsNewPresentationHistory` presents each version at most once per
device.

Then cut the branch from that commit. It is named for the **minor** version, not the patch —
`release/1.11` carries `1.11.0`, `1.11.1`, and every later patch. It is long-lived: do not delete
it until the next minor ships.

```bash
git switch -c release/{major}.{minor}
git push -u origin release/{major}.{minor}
```

The `release branches` repository ruleset covers `refs/heads/release/**` — deletion protection,
linear history, and required `unit-tests` + `DCO` checks — so contributor PRs into this branch
are gated exactly like `main`.

From here until Mode C, **all release work happens on this branch.** `main` stays open for the
next version's features. If the release is abandoned or renumbered after this point, reverting this
one commit on `main` undoes all of it together.

## A5. Set the candidate build number

On the release branch, set `CURRENT_PROJECT_VERSION` to `"1"` — the first candidate build of this
version — on **all four** product targets in `project.yml` (`KeeForge`, `KeeForgeAutoFill`,
`KeeForgeMac`, `KeeForgeMacAutoFill`). They must always carry identical values; there are exactly 4
values to update. Use precise string-replacement edits.

`MARKETING_VERSION` is already correct from A4.

## A6. Regenerate and run the local KDBX gate

```bash
xcodegen generate
```

Run the KDBX compatibility gate in a fresh `bash` session, under the repo's Xcode lock. This is a
required local gate for **every candidate build** — Xcode Cloud does not install KeePassXC, so
the release machine is the only place KeeForge-written databases are cross-validated against
another KeePass implementation:

```bash
LOG=/Users/tan/src/KeeForge/scratch/xcode-logs/$(date +%Y%m%d-%H%M%S)-kdbx-gate.log
mkdir -p "$(dirname "$LOG")"
/Users/tan/src/KeeForge/scripts/with-repo-lock.sh xcode -- \
  ci_scripts/run_kdbx_compatibility_gate.sh > "$LOG" 2>&1
echo "exit=$? log=$LOG"
```

If `keepassxc-cli` is not installed, stop and ask the user to install KeePassXC (or point
`KEEPASSXC_CLI` at the binary). Do not skip this gate or proceed past a failure.

Do **not** run the full unit or UI suites locally here — both cloud systems run them in A8.

## A7. Commit, push, and tag the candidate

1. Stage the changed files. The changelog and What's New content already landed on `main` in A4,
   so a first candidate normally only carries the version bump and the regenerated project:
   ```bash
   git add project.yml KeeForge.xcodeproj
   ```
   Add `CHANGELOG.md` and the What's New files too if this candidate actually changed them.
2. Commit with `-s`: `Release candidate v{version} build {build}`
3. Push the branch: `git push origin release/{major}.{minor}`
4. Tag the candidate. **One tag per build**, carrying the build number so the tag identifies the
   commit each candidate was built from:
   ```bash
   git tag -a rc/{version}-b{build} -m "RC v{version} build {build}"
   git push origin rc/{version}-b{build}
   ```

The tag push triggers Xcode Cloud's RC workflow (test, and archive and upload to TestFlight) and
`.github/workflows/ios18-rc-tests.yml`.

## A8. Wait for both test gates

The RC tag starts two independent full-suite runs. Both must be accepted before the build is
distributed to external testers.

1. Monitor Xcode Cloud through GitHub — it mirrors onto the RC commit as a check run:
   ```bash
   gh api repos/KeeForge/KeeForge/commits/{rc-sha}/check-runs \
     --jq '.check_runs[] | select(.app.name=="Xcode Cloud") | "\(.name) | \(.status) | \(.conclusion // "-")"'
   ```
2. Monitor GitHub Actions:
   ```bash
   gh run list --workflow ios18-rc-tests.yml --event push
   gh run watch <run-id> --exit-status
   ```
   Find the run whose `headBranch` is the RC tag and whose `headSha` is the RC commit.
3. Record each run's URL, commit SHA, status, and conclusion. Both must target the RC commit.
4. If either gate is not green, **read `gate-adjudication.md`** and follow it. Do not distribute a
   build whose gates are unresolved.

Xcode Cloud's test and archive actions run in parallel. A red test action still uploads a build,
but its `TestFlight External Testing` post-action does not run — see gate-adjudication.md for
whether that build may be distributed by hand.

## A9. Release the build to external testers

1. Find the build in App Store Connect under TestFlight for marketing version `{version}`.
   **Its build number will not be the one in `project.yml`** — Xcode Cloud assigns its own,
   monotonically increasing per app, and there is no supported way to disable that. Match on the
   commit instead: the Xcode Cloud build page shows the `rc/{version}-b{build}` tag and SHA it was
   built from. Record the TestFlight build number alongside the candidate tag; every later step
   refers to the TestFlight number. Export compliance does not prompt (see Notes).
2. Write **What to Test** notes for the build. This is the only text every tester sees, and it is
   the steering channel for the soak. Always include:
   - What changed in this build, in user terms.
   - **"Test against a copy of your database, not your primary vault."** A TestFlight build shares
     the production bundle ID and container, so testers are running an unreviewed candidate
     against their real KDBX files.
   - Any area you specifically want exercised.
3. If this is the **first build of this marketing version**, submit for Beta App Review and expect
   roughly a day before external distribution. Later builds of the same version normally skip it.
   Do not announce a ship date until this clears. Until it does, the published public link shows
   *"This beta isn't accepting any new testers right now"* to everyone arriving from `README.md`
   or keeforge.com — expected, and another reason not to announce early.
4. Distribute to the public-link group. The link is permanently enabled and published, so this
   reaches every tester accumulated from earlier releases, not just people who opted into this one.
5. Record the distribution timestamp — the soak clock starts here, not at the branch cut.

## A10. Soak

Shipping is the user's call. These are targets, not gates — but they are **always measured and
always reported**. Never summarize the soak as "looks fine"; give the four numbers and a
recommendation, then let the user decide.

Targets for the **current** build (a minor release; patches use 24h — see D4):

| Signal | Where to read it | Target |
| --- | --- | --- |
| Time since this build reached external testers | distribution timestamp recorded in A9 | 48h |
| Unique installs of this exact build | App Store Connect → TestFlight | 5 |
| New crash signatures for this build | TestFlight → Crashes, and Xcode Organizer | 0 |
| Open P0/P1 reports | TestFlight → Feedback, `feedback.keeforge.com` | none |

Report each signal as **met** or **short**, with its actual value, and state plainly what is
being accepted by shipping early. "18h of a 48h target, 2 installs, no crashes, one P2 open" is a
useful thing for the user to weigh; "soak complete" is not.

Two habits keep this honest when the targets are relaxed:

- **A new build resets the clock.** Elapsed time and installs belong to one build; they do not
  carry over from the candidate it replaced. Report the current build's numbers, never the
  version's cumulative ones.
- **Record what was accepted.** When shipping short of target, note which signals were short in
  the `v{version}` tag message (C4). This costs nothing and makes the pattern visible over several
  releases, which is the thing worth knowing.

Watch all three feedback channels: screenshot feedback, Send Beta Feedback text, and crash
reports — all under **TestFlight → Feedback** in App Store Connect.

Some candidates deserve a real hold regardless of the clock. Say so explicitly, and recommend
against shipping short, when the build touches `KDBXParser`, `KDBX3Parser`, `KDBXWriter`,
`KDBXXMLSerializer`, or the local/cloud save paths — a bad write reaches users' real vaults, and
the App Store rollback story is "ship another version."

When the user is satisfied, go to **Mode C**.

---

# Mode B — Respin a candidate build

Use when a fix must land on a live release branch. Every respin produces a new build and restarts
the soak clock.

## B1. Land the fix on the release branch

The fix goes on the release branch **first** — that is where it is needed. Contributor fixes come
in as PRs targeting `release/{major}.{minor}` and are gated by `pr-tests.yml` and the ruleset.

Never amend or force-push an existing release commit; the fix is always a new commit.

## B2. Bump the build number

In `project.yml`, increment `CURRENT_PROJECT_VERSION` by 1 on **both** the `KeeForge` and
`KeeForgeAutoFill` targets. `MARKETING_VERSION` does not change.

If the fix warrants a user-visible changelog line, add it to the version's section in
`CHANGELOG.md` (not `## Unreleased` — this version is no longer unreleased on this branch).

## B3. Regenerate, gate, tag

Run A6 (regenerate + KDBX gate), then A7 with the new build number, then A8 and A9.

The KDBX gate runs again for this build. It is not inherited from the previous candidate.

## B4. Restart the soak

Return to A10 with the clock reset to this build's distribution timestamp. Prior builds' soak time
does not carry over.

## B5. Merge the release branch back into main

Do this as soon as the fix lands, not at ship time — a fix that exists only on the release branch
regresses the moment `main` becomes the next release.

Merge the whole branch; do not cherry-pick individual commits. A merge makes "is every release fix
on main?" an exact question git can answer, which cherry-picking cannot.

```bash
git switch main
git pull --ff-only
git merge --no-ff origin/release/{major}.{minor} \
  -m "Merge release/{major}.{minor} into main (v{version} build {build})"
git push origin main
```

`CHANGELOG.md` is the likeliest conflict, though A4 removes most of it by putting the
`## v{version}` section on `main` before the cut. It can still happen when a respin adds a bullet
to the version section while `main` has accumulated new `## Unreleased` entries. Resolve by keeping
both — `## Unreleased` with main's newer entries on top, the version section below it.

The merge also carries the release mechanics (version bump, build numbers, What's New content) to
`main`. That is intended, and it is why Mode C has no separate sync step.

---

# Mode C — Ship the soaked build

Enter this mode when the user decides to ship, after the A10 signals have been reported to them.

**Do not re-check the CI gates here.** Both gates were read and adjudicated in A8, and accepting
them is what allowed the build to reach external testers in the first place (invariant 3). That
verdict is Mode A's job and it is final: do not poll Xcode Cloud or GitHub Actions check runs for
the RC commit, do not reopen `gate-adjudication.md`, and do not treat a test action that was red but
accepted as a flake — or a later re-run of either workflow — as a reason to stop. The soaked binary
already carries the verdict. If it turns out a gate was never accepted, you are not in Mode C; go
back to A8.

## C1. Confirm what you are shipping

Record explicitly, and state it back to the user before proceeding:

- The marketing version and the **TestFlight** build number of the soaked build.
- Its `rc/{version}-b{build}` tag and commit SHA. Note these disagree by design: the candidate tag
  says `b3` where TestFlight says build 39, because Xcode Cloud renumbers. The tag identifies the
  commit; the TestFlight number identifies the binary.
- The distribution timestamp and elapsed soak time.
- The unique-install count and crash count.
- Which A10 signals, if any, are short of target.

The TestFlight build number here **is** the build you will select in App Store Connect. If it does
not match the build you distributed and soaked, stop — something is out of sync. Do not compare it
against `CURRENT_PROJECT_VERSION`; those never match.

## C2. Audit that main has every fix

Because backports are merges, this is an exact check rather than a judgement call:

```bash
git fetch origin --tags
git merge-base --is-ancestor origin/release/{major}.{minor} origin/main \
  && echo "main contains the release branch" \
  || git log --oneline origin/main..origin/release/{major}.{minor}
```

If the check fails, the listed commits are on the release branch and not on `main`. Run Mode B5 to
merge them before shipping. Do not ship with an unmerged fix.

## C3. Correct the changelog date if the soak crossed a day

If `CHANGELOG.md`'s `## v{version} ({date})` no longer matches the actual ship date, fix it on the
release branch now. This is a documentation-only change and does **not** require a new build — the
changelog is not compiled into the binary.

## C4. Tag the shipped build

`v{version}` is a permanent record of what shipped. It triggers no build.

```bash
git fetch origin --tags
rc_tag='rc/{version}-b{build}'
rc_commit=$(git rev-list -n1 "$rc_tag")
git tag -a 'v{version}' -m 'Release v{version} — shipped build {build} (from '"$rc_tag"')' "$rc_commit"
git push origin 'refs/tags/v{version}'
```

If any A10 signal was short of target, add a line to the tag message saying which and why — for
example `Shipped at 18h of 48h: fix confirmed by reporter, no crashes.` One sentence is enough.

Keep every `rc/*` tag. They are the audit trail of the candidates, including the ones that were
replaced.

If `git fetch origin --tags` reports `! [rejected] ... (would clobber existing tag)`, a local tag
has drifted from the remote. The remote is authoritative for released tags: inspect both sides,
then realign with `git fetch origin --tags --force`.

## C5. Confirm main reflects the shipped state

A4 put the changelog section, the What's New content, and `MARKETING_VERSION` on `main` before the
cut, and the B5 merges carried each candidate's build number across. Verify rather than redo:

- `main`'s `MARKETING_VERSION` is `{version}` on both the `KeeForge` and `KeeForgeAutoFill` targets.
- `main`'s `CHANGELOG.md` has the `## v{version}` section, with an empty `## Unreleased` above it
  ready for the next cycle.

`CURRENT_PROJECT_VERSION` is **not** checked against TestFlight. Xcode Cloud manages build numbers
itself and overrides whatever the project carries — `rc/1.11.0-b3` shipped as TestFlight build 39 —
so the two disagreeing is the normal state, not drift. Apple exposes no supported way to turn that
off. What matters is that the repo's build numbers stay unique and increasing per candidate, which
A5 and B2 already guarantee.

Fix any real drift with a single `-s` commit on `main`, then push.

## C6. Hand off to App Store Connect

Invoke the `publish-app-store-version` skill. Give it the exact marketing version **and build
number** from C1 — that skill selects an already-uploaded build and must not trigger a new one.

Keep the release branch. It is where `{version}.1` will come from.

---

# Mode D — Patch a shipped version

For `1.11.1` on top of a shipped `1.11.0`.

## D1. Branch is already there

Patches are cut from the existing `release/{major}.{minor}` branch — **never from `main`**, which
by now carries the next version's features.

```bash
git switch release/{major}.{minor}
git pull --ff-only
```

Verify the branch tip is at or after the `v{major}.{minor}.0` tag.

## D2. Land the fix and bump

1. Land the fix (Mode B1) and port it to `main` (Mode B5).
2. In `project.yml`, set `MARKETING_VERSION` to the patch version and reset
   `CURRENT_PROJECT_VERSION` to `"1"`, on both targets.
3. Add a `## v{version} ({date})` section to `CHANGELOG.md` above the previous version's section.
4. Run A3 only if the patch has a user-visible highlight worth a What's New sheet. Most patches do
   not; confirm `WhatsNewCatalog` has no case rather than shipping an empty sheet.

## D3. Gate, tag, distribute

Run A6, A7, A8, and A9 exactly as for a minor release. The KDBX gate is not optional for patches.

## D4. Shortened soak

Patch releases target **24h** instead of 48h. Every other A10 signal is measured and reported the
same way.

When the patch fixes an active crash or data-loss bug already reaching users, recommend shipping
as soon as both A8 gates are green — for that class of bug, more soak time is usually worse for
users than less. Say that explicitly rather than leaving the user to infer it.

The gates themselves are still invariant 3: green, or every failure adjudicated. A patch under
time pressure is exactly when it is tempting to skip them, and exactly when a second bad build
does the most damage.

## D5. Ship

Continue with Mode C from C1, reporting against the 24h target in place of 48h.

---

# Notes

- The macOS targets ship in lockstep with iOS: all four product targets carry the same
  `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, bumped together in A4 and A5.
- **One release branch covers both platforms.** `release/{major}.{minor}` is not per-platform, and
  neither is `rc/{version}-b{build}`: one candidate tag fires `ios18-rc-tests.yml`,
  `macos-rc-tests.yml`, and the Xcode Cloud RC workflow together, and the build they all test is
  the build both platforms ship. Splitting the branch would mean splitting the version numbers,
  which is the thing lockstep exists to prevent. A platform-specific fix still goes onto the shared
  release branch and respins one candidate for both.
- The two platforms diverge only at App Store Connect, which keeps a **separate version record,
  build, screenshot set, and review submission per platform**. Shipping is therefore not done when
  iOS is submitted; see the `publish-app-store-version` skill.
- The KDBX compatibility gate runs **per platform**. Run it for iOS as documented, then again with
  `KDBX_COMPAT_SCHEME=KeeForgeMac` (which switches the test target to `KeeForgeMacTests` and the
  destination to `platform=macOS`). Both must pass before a candidate ships.
- The Mac ships through **two channels**. The Mac App Store build is the default
  (`xcodegen generate`) and is archived like the iOS app. The notarized
  Developer ID build is produced by `ci_scripts/build_mac_direct.sh`, which
  regenerates from the `project-direct.yml` overlay spec, archives, exports,
  refuses to submit anything that is unsandboxed or carries a
  `com.apple.security.cs.*` exception, notarizes, staples, and emits the appcast
  zip. Run it **after** the App Store build is cut, from the same commit, so both
  channels ship identical code — then sign the zip with Sparkle's `sign_update`
  and publish the appcast entry.
- `KeeForgeMacUITests` cannot run on a headless runner — it needs an unlocked, active login session
  — so the Mac smoke suite stays a **local** pre-release step. `.github/workflows/macos-rc-tests.yml`
  covers the Mac unit suite on each `rc/*` tag.
- `ITSAppUsesNonExemptEncryption` is declared `false` in `KeeForge/Info.plist` and
  `KeeForgeMac/Info.plist`, so App Store Connect
  does not ask the export-compliance question per build. It remains a legal declaration: if the
  app's cryptography changes materially, revisit it rather than assuming the key still applies.
