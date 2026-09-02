---
name: release
description: >
  Run the KeeForge three-channel release process: cut a release/{major}.{minor} branch, build
  iOS, Mac App Store, and direct-download Mac candidates from one immutable RC, soak the exact
  artifacts, and ship the exact accepted builds. Bumps versions and the globally monotonic repo
  build in project.yml, updates CHANGELOG.md and the What's New sheet, runs both local KDBX
  compatibility gates plus the local Mac smoke, and pushes rc/{version}-b{repoBuild} tags so Xcode
  Cloud and both GitHub Actions workflows test and archive each candidate.
  Use this skill whenever the user wants to cut a release, start a release branch, respin a
  release candidate, ship a soaked build, bump the version, or prepare a build for
  TestFlight/App Store. Triggers on phrases like "release", "new version", "bump version",
  "cut a release", "prepare release", "ship it", "release candidate", "respin", "new RC build",
  "hotfix", or "push a new build".
---

# KeeForge Release Workflow

Releases run on one dedicated `release/{major}.{minor}` branch. Each candidate produces three
artifacts from one commit: an iOS App Store/TestFlight build, a Mac App Store/TestFlight build,
and a notarized direct-download Mac build. Archives/uploads may be automatic, but the two App Store
builds are moved manually to their respective external TestFlight groups only after every required
gate is accepted; the direct build is staged and soaked separately. Ship only those exact artifacts.
This is a sequential, high-stakes workflow: each step depends on the previous one succeeding. Do not
skip steps or proceed past a failure.

Test execution model: the full unit suites and hosted UI suites run on **Xcode Cloud** and
**GitHub Actions**. `KeeForgeMacUITests/MacSmokeUITests` is the required local UI smoke because it
needs an unlocked active login session. Do not run the full hosted suites locally up front. Run
focused local XCTest reproductions only when a cloud test fails — see `gate-adjudication.md`.

## Shared release state and manifest

The release handoff is one state record, not a single build number:

`{version, repoBuild, rcTag, commitSHA, iosTestFlightBuild, macTestFlightBuild, directCFBundleVersion}`.

`repoBuild` is the globally monotonic `CURRENT_PROJECT_VERSION` in `project.yml`; it increases for
every minor, major, patch, and respin candidate and is identical on `KeeForge`,
`KeeForgeAutoFill`, `KeeForgeMac`, and `KeeForgeMacAutoFill`. It is never reset for a new marketing
version. The direct build's `CFBundleVersion` is this repo build. Xcode Cloud may assign separate,
platform-specific TestFlight build numbers; record both and match each back to the RC tag and SHA.
Do not compare either TestFlight number with `repoBuild` or force the platform numbers to match.

During a release, record the state in `scratch/release-manifests/{version}-b{repoBuild}.json`.
That path is gitignored and is working state, not a secret store. The manifest must contain only
non-secret evidence: `schemaVersion`, `version`, `repoBuild`, `rcTag`, `commitSHA`, `sourceTree`,
both platform build numbers/version records, distribution timestamps and soak metrics, all gate
verdicts/URLs or log paths, direct zip filename/URL/SHA-256, Sparkle signature attributes,
notarization ID, archive/symbol locations, review states, release timestamps, and accepted soak
exceptions. Never put passwords, tokens, App Store Connect credentials, private signing keys,
keychain profiles, or cloud secret values in it or in logs. At ship time preserve the completed
non-secret manifest with the release evidence (for example, GitHub Release notes/asset or the
team's secure release archive); the scratch copy is not the long-term record.

## The four invariants

Violating any of these invalidates the release. They outrank convenience at every step, and
unlike the soak targets in A10 they are not judgement calls.

1. **Ship exactly what was soaked.** Select the iOS and Mac App Store builds from TestFlight and
   publish the staged direct zip; never re-archive or substitute a newer build after soaking.
2. **Every candidate has one globally increasing repo build and one immutable RC tag.** All four
   product targets carry that repo build. Xcode Cloud's iOS and Mac TestFlight numbers may differ
   from it and from each other, so the manifest maps all three artifacts to the same SHA.
3. **All gates are accepted before external distribution.** Accept the Xcode Cloud verdict, the
   iOS 18 GitHub Actions verdict, the macOS GitHub Actions verdict, both local KDBX gates, and the
   local Mac smoke suite; green or explicitly adjudicated per `gate-adjudication.md`. Before
   external distribution or direct-artifact staging, both exact exported Mac apps must also pass
   `ci_scripts/verify_mac_artifact.sh` with universal `arm64,x86_64`, unless an explicit product
   decision records a different architecture set.
4. **Tags are immutable and `v{version}` is post-approval evidence.** Never delete, move, or
   force-push an `rc/*` tag. Create `v{version}` only after both App Store submissions have code
   approval and the final go decision; it triggers no build.

## Pick the mode first

Identify which mode applies before touching anything. Ask the user if it is ambiguous.

| Situation | Mode |
| --- | --- |
| Starting a new minor/major version, no branch yet | **A — Cut** |
| Release branch exists, a fix needs a new candidate build | **B — Respin** |
| Soak criteria met, ready for the App Store | **C — Ship** |
| Shipped version needs a patch (`1.11.1`) | **D — Patch** |

Reference files, read on demand:

- `gate-adjudication.md` — how to read cloud check runs and adjudicate test failures locally.
  Read this whenever a cloud gate is not green in A8; apply the same test-vs-infrastructure
  distinction to the macOS workflow and never override a non-test failure with a local pass.
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
The Mac targets ship in lockstep with iOS (same marketing version and repo build). Leave
`CURRENT_PROJECT_VERSION` alone here; A5 advances it globally for the first candidate.

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

Determine `repoBuild` mechanically; never guess from the latest TestFlight number or from a single
working-tree value. The new four-target invariant begins with this process: older revisions may
predate the Mac targets and may contain unequal or reset build values. Scan those revisions for
every numeric value belonging to whichever of the four targets existed, using their maximum only as
the legacy floor. Separately require the current working tree to satisfy the new invariant. First
fetch the refs used for release bookkeeping, then validate every present new-process manifest. Run
this in a fresh Bash shell; any failed check is a stop, not a reason to fall back to a guessed value:

```bash
set -euo pipefail
git fetch origin --tags 'refs/heads/release/*:refs/remotes/origin/release/*'
refs=(HEAD)
while read -r ref; do refs+=("$ref"); done < <(
  git for-each-ref --format='%(refname)' refs/heads/release refs/remotes/origin/release refs/tags/rc refs/tags/v
)

target_values() {
  awk '
    /^  (KeeForge|KeeForgeAutoFill|KeeForgeMac|KeeForgeMacAutoFill):$/ { target=$1; sub(/:$/, "", target); next }
    /^  [^ ]/ { target="" }
    target && /CURRENT_PROJECT_VERSION:/ {
      value=$0; sub(/^.*CURRENT_PROJECT_VERSION:[[:space:]]*"?/, "", value); sub(/"[[:space:]]*$/, "", value)
      if (value ~ /^[0-9]+$/) print target ":" value
    }
  ' "${1:--}"
}

historical_values() {
  target_values "${1:--}" | cut -d: -f2
}

check_current_project() {
  local file=${1:--} rows names expected values
  rows=$(target_values "$file")
  test "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" -eq 4
  names=$(printf '%s\n' "$rows" | cut -d: -f1 | sort)
  expected=$(printf '%s\n' KeeForge KeeForgeAutoFill KeeForgeMac KeeForgeMacAutoFill | sort)
  test "$names" = "$expected"
  values=$(printf '%s\n' "$rows" | cut -d: -f2 | sort -u)
  test "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" -eq 1
  printf '%s\n' "$values"
}

commits=$(for ref in "${refs[@]}"; do git rev-list "$ref" -- project.yml; done | sort -u)
test -n "$commits"
history_values=$(while read -r sha; do git show "$sha:project.yml" 2>/dev/null | historical_values; done <<<"$commits")
test -n "$history_values"
current_value=$(check_current_project project.yml)
test -n "$current_value"

manifest_values=""
while read -r manifest; do
  test -n "$manifest"
  manifest_build=$(jq -er '.repoBuild | select(type == "number" and floor == .)' "$manifest")
  expected_tag="rc/$(jq -er '.version | strings' "$manifest")-b${manifest_build}"
  case "$(basename "$manifest")" in
    *"-b${manifest_build}.json") ;;
    *) echo "manifest filename does not match repoBuild: $manifest" >&2; exit 1 ;;
  esac
  test "$(jq -er --arg tag "$expected_tag" 'select(.rcTag == $tag) | .repoBuild' "$manifest")" = "$manifest_build"
  manifest_values+="${manifest_build}\n"
done < <(find scratch/release-manifests -type f -name '*.json' -print 2>/dev/null || true)

all_values=$(printf '%b\n%b' "$history_values" "$manifest_values" | sed '/^$/d' | sort -n -u)
test -n "$all_values"
printf 'validated repo builds: %s\n' "$all_values"
repoBuild=$(( $(printf '%s\n' "$all_values" | tail -n 1) + 1 ))
printf 'next repoBuild: %s\n' "$repoBuild"
```

Stop if the current `project.yml` does not contain exactly one numeric
`CURRENT_PROJECT_VERSION` for each of `KeeForge`, `KeeForgeAutoFill`, `KeeForgeMac`, and
`KeeForgeMacAutoFill`, or if those four current values differ. Historical revisions are not required
to satisfy this new invariant: absent Mac targets, unequal values, and old resets are tolerated, but
only numeric values from an existing target contribute to the legacy floor. Stop if a present
new-process manifest is malformed/missing `repoBuild`, or if its `repoBuild` disagrees with its
filename/RC tag. The greatest validated value across reachable project history and manifests is the
previous global maximum; set `repoBuild` to exactly that value plus one on all four current targets.
Re-check that all four current values are identical before committing and record the result in the
new manifest. A missing project history or no usable numeric historical value is not evidence that
the floor is zero; stop and resolve the scope instead. A manifest from a different release may
legitimately have a lower build; only malformed or internally inconsistent evidence is a disagreement.

`MARKETING_VERSION` is already correct from A4.

## A6. Regenerate and run the local KDBX gate

```bash
xcodegen generate
```

Run the KDBX compatibility gate twice in a fresh `bash` session, under the repo's Xcode lock. Both
are required for **every candidate build** — Xcode Cloud does not install KeePassXC, so the release
machine is the only place KeeForge-written databases are cross-validated against another KeePass
implementation:

```bash
LOG=/Users/tan/src/KeeForge/scratch/xcode-logs/$(date +%Y%m%d-%H%M%S)-kdbx-gate.log
mkdir -p "$(dirname "$LOG")"
/Users/tan/src/KeeForge/scripts/with-repo-lock.sh xcode -- \
  ci_scripts/run_kdbx_compatibility_gate.sh > "$LOG" 2>&1
echo "exit=$? log=$LOG"
```

Repeat with `KDBX_COMPAT_SCHEME=KeeForgeMac` and a separate log. Record both verdicts/paths as
`gates.kdbxIOS` and `gates.kdbxMac`.

If `keepassxc-cli` is not installed, stop and ask the user to install KeePassXC (or point
`KEEPASSXC_CLI` at the binary). Do not skip this gate or proceed past a failure.

Do **not** run the full unit or UI suites locally here — the cloud systems run them in A8. The
required local Mac smoke is the only UI exception.

## A7. Commit, push, and tag the candidate

1. Stage the changed files. The changelog and What's New content already landed on `main` in A4,
   so a first candidate normally only carries the version bump and the regenerated project:
   ```bash
   git add project.yml KeeForge.xcodeproj
   ```
   Add `CHANGELOG.md` and the What's New files too if this candidate actually changed them.
2. Commit with `-s`: `Release candidate v{version} repo build {repoBuild}`
3. Push the branch: `git push origin release/{major}.{minor}`
4. Tag the candidate. **One tag per build**, carrying the build number so the tag identifies the
   commit each candidate was built from:
   ```bash
   git tag -a rc/{version}-b{repoBuild} -m "RC v{version} repo build {repoBuild}"
   git push origin rc/{version}-b{repoBuild}
   ```

The tag push triggers Xcode Cloud's RC workflow (iOS and Mac tests plus MAS archives/uploads),
`.github/workflows/ios18-rc-tests.yml`, and `.github/workflows/macos-rc-tests.yml`.

## A8. Wait for all cloud gates and local Mac smoke

The RC tag starts three cloud verdicts. All three, plus the two KDBX verdicts from A6 and the
local Mac smoke suite, must be accepted before either App Store build is distributed to external
testers or the direct build is called a release candidate.

1. Monitor Xcode Cloud through GitHub — it mirrors onto the RC commit as check runs for the iOS
   and Mac actions:
   ```bash
   gh api repos/KeeForge/KeeForge/commits/{rc-sha}/check-runs \
     --jq '.check_runs[] | select(.app.name=="Xcode Cloud") | "\(.name) | \(.status) | \(.conclusion // "-")"'
   ```
2. Monitor the iOS GitHub Actions gate:
   ```bash
   gh run list --workflow ios18-rc-tests.yml --event push
   gh run watch <run-id> --exit-status
   ```
   Find the run whose `headBranch` is the RC tag and whose `headSha` is the RC commit.
3. Monitor the macOS GitHub Actions gate using `macos-rc-tests.yml` and match its `headSha` to the
   RC commit.
4. Record all three URLs, commit SHA, status, and conclusion in the manifest. The Xcode Cloud,
   iOS, and Mac runs must target the same RC commit.
5. Run `KeeForgeMacUITests/MacSmokeUITests` locally on an unlocked release Mac under the repo
   Xcode lock. Record its result and log/result bundle path as `gates.localMacSmoke`.
6. If any cloud gate is not green, **read `gate-adjudication.md`** and follow it. Do not distribute
   a build whose gates are unresolved; a local pass cannot override a non-test infrastructure
   failure.

Xcode Cloud's test and archive actions run in parallel. A red test action may still upload a build,
but that build remains blocked from external distribution until the failure is adjudicated and all
required gates are accepted. External TestFlight distribution is always a deliberate manual action
in App Store Connect, independently for iOS and Mac.

## A9. Verify all three artifacts and manually distribute the App Store builds

1. Find both processed builds in App Store Connect under TestFlight for marketing version
   `{version}`. Their numbers may differ from `repoBuild` and from each other because Xcode Cloud
   assigns platform-specific numbers. Match each build to the `rc/{version}-b{repoBuild}` tag and
   SHA, then record `iosTestFlightBuild` and `macTestFlightBuild` in the manifest. Export compliance
   does not prompt (see Notes).
2. Obtain/export the exact MAS `.app` from the accepted Xcode Cloud archive without rebuilding.
   Run the artifact check on that exact exported app:
   ```bash
   ci_scripts/verify_mac_artifact.sh --channel mas --app <exact-mas-app> --architectures arm64,x86_64
   ```
   Do not substitute a local rebuild or a different archive. The expected architecture set is the
   universal `arm64,x86_64`; a different set requires an explicit product decision recorded in the
   manifest before continuing.
3. Run `ci_scripts/build_mac_direct.sh` from the same clean RC SHA, verify its direct
   `CFBundleVersion` equals the repo build, and run the same fail-closed check on its exact exported
   app:
   ```bash
   ci_scripts/verify_mac_artifact.sh --channel direct --app <exact-direct-app> --architectures arm64,x86_64
   ```
   Both artifact checks must pass before any external distribution or direct-artifact staging.
   Then run `ci_scripts/release_direct_artifact.sh stage` to generate a complete unpublished appcast
   while preserving older items and recording the base-feed hash. Do not run `handoff` until C7's
   post-approval go decision.
4. Write platform-specific **What to Test** notes for each build. These are the only text each
   tester group sees, and are the steering channel for the soak. Always include:
   - What changed in this build, in user terms.
   - **"Test against a copy of your database, not your primary vault."** A TestFlight build shares
     the production bundle ID and container, so testers are running an unreviewed candidate
     against their real KDBX files.
   - Any area you specifically want exercised.
5. If this is the **first build of this marketing version/platform**, obtain explicit action-time user
   confirmation immediately before submitting it for Beta App Review and expect roughly a day before
   external distribution. Later builds of the same version normally skip it. Do not announce a ship
   date until this clears. Until it does, the published public link shows
   *"This beta isn't accepting any new testers right now"* to everyone arriving from `README.md`
   or keeforge.com — expected, and another reason not to announce early.
6. Obtain separate explicit action-time user confirmation immediately before distributing each
   platform to its external group. This is a manual App Store Connect action; do not batch the
   confirmation across iOS and Mac. The iOS public link is permanently enabled and published, so
   distribution reaches every tester accumulated from earlier releases, not just people who opted
   into this one.
7. Record each platform's distribution timestamp — the soak clocks start here, not at the branch
   cut.
   The direct artifact has no TestFlight metrics and is tested separately in A10.

## A10. Soak

Shipping is the user's call. These are targets, not gates — but they are **always measured and
always reported**. Never summarize the soak as "looks fine"; give the four numbers and a
recommendation, then let the user decide.

Targets for the **current** build (a minor release; patches use 24h — see D4):

| Signal | Where to read it | Target |
| --- | --- | --- |
| Time since each App Store build reached external testers | platform distribution timestamps recorded in A9 | 48h |
| Unique installs of each exact App Store build | App Store Connect → each platform's TestFlight | 5 |
| New crash signatures for each App Store build | TestFlight → Crashes, and Xcode Organizer | 0 |
| Open P0/P1 reports | TestFlight → Feedback, `feedback.keeforge.com` | none |

For the direct Mac artifact, record install success on clean Apple-silicon and Intel hardware/VMs,
launch/quarantine behavior, and the full Sparkle update cycle separately; it has no TestFlight
metrics.

Report each App Store signal as **met** or **short**, with its actual value, and report direct Mac
install/update results separately. State plainly what is being accepted by shipping early.
"18h of a 48h target, 2 iOS installs, 1 Mac install, no crashes, one P2 open" is useful; "soak
complete" is not. Both App Store builds and the direct artifact must still be the same accepted RC.

Two habits keep this honest when the targets are relaxed:

- **A new build resets the clock.** Elapsed time and installs belong to one build; they do not
  carry over from the candidate it replaced. Report the current build's numbers, never the
  version's cumulative ones.
- **Record what was accepted.** When shipping short of target, note which signals were short in
  the `v{version}` tag message (C5). This costs nothing and makes the pattern visible over several
  releases, which is the thing worth knowing.

Watch all three feedback channels: screenshot feedback, Send Beta Feedback text, and crash
reports — all under **TestFlight → Feedback** in App Store Connect.

Some candidates deserve a real hold regardless of the clock. Say so explicitly, and recommend
against shipping short, when the build touches `KDBXParser`, `KDBX3Parser`, `KDBXWriter`,
`KDBXXMLSerializer`, or the local/cloud save paths — a bad write reaches users' real vaults, and
the App Store rollback story is "ship another version."

When the user is satisfied, go to **Mode C**. Do not create `v{version}` until both platform
submissions have code approval and the final go decision.

---

# Mode B — Respin a candidate build

Use when a fix must land on a live release branch. Every respin produces a new build and restarts
the soak clock.

## B1. Land the fix on the release branch

The fix goes on the release branch **first** — that is where it is needed. Contributor fixes come
in as PRs targeting `release/{major}.{minor}` and are gated by `pr-tests.yml` and the ruleset.

Never amend or force-push an existing release commit; the fix is always a new commit.

## B2. Bump the build number

In `project.yml`, increment the globally monotonic `CURRENT_PROJECT_VERSION` by 1 on **all four**
targets: `KeeForge`, `KeeForgeAutoFill`, `KeeForgeMac`, and `KeeForgeMacAutoFill`. Never reset it;
`MARKETING_VERSION` does not change. Update `repoBuild` in the new manifest and rebuild iOS, MAS,
and direct artifacts from the new RC commit.

If the fix warrants a user-visible changelog line, add it to the version's section in
`CHANGELOG.md` (not `## Unreleased` — this version is no longer unreleased on this branch).

## B3. Regenerate, gate, tag

Run A6 (regenerate + KDBX gate), then A7 with the new build number, then A8 and A9.

Both KDBX gates run again for this build. They are not inherited from the previous candidate.

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
  -m "Merge release/{major}.{minor} into main (v{version} repo build {repoBuild})"
git push origin main
```

`CHANGELOG.md` is the likeliest conflict, though A4 removes most of it by putting the
`## v{version}` section on `main` before the cut. It can still happen when a respin adds a bullet
to the version section while `main` has accumulated new `## Unreleased` entries. Resolve by keeping
both — `## Unreleased` with main's newer entries on top, the version section below it.

The merge carries the release mechanics (version bump, repo build, and What's New content) to
`main`; that is intended, so Mode C has no separate sync step.

---

# Mode C — Ship the soaked build

Enter this mode when the user decides to ship, after the A10 signals have been reported to them.

**Do not re-check the CI gates here.** All cloud gates and local gates were read and adjudicated in A8, and accepting
them is what allowed the build to reach external testers in the first place (invariant 3). That
verdict is Mode A's job and it is final: do not poll Xcode Cloud or GitHub Actions check runs for
the RC commit, do not reopen `gate-adjudication.md`, and do not treat a test action that was red but
accepted as a flake — or a later re-run of either workflow — as a reason to stop. The soaked binary
already carries the verdict. If it turns out a gate was never accepted, you are not in Mode C; go
back to A8.

## C1. Confirm what you are shipping

Record explicitly, and state it back to the user before proceeding:

- The marketing version, repo build, and both **TestFlight** build numbers of the soaked builds.
- Its `rc/{version}-b{repoBuild}` tag and commit SHA. The tag identifies the commit; each
  platform-specific TestFlight number identifies its binary, and neither is required to equal the
  repo build.
- The direct Mac `CFBundleVersion`, zip hash, and notarization ID.
- Both distribution timestamps, elapsed soak times, unique-install/crash counts, and direct install/update results.
- Which A10 signals, if any, are short of target.

Each TestFlight build number here **is** the build you will select for its platform in App Store
Connect. If either does not match the build distributed and soaked, stop — something is out of
sync. Do not substitute a newer build.

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

## C4. Stage both App Store submissions; do not create the shipped tag yet

Invoke `publish-app-store-version` once for iOS and once for macOS. Attach the exact soaked
TestFlight build numbers from the manifest, save the platform-specific metadata/screenshots, and
stage each platform independently through **Ready for Review**, then stop. Do not submit either
platform yet. If the user later requests submission, obtain separate explicit action-time
confirmation immediately before each platform's **Submit for Review** click; confirmation for one
platform does not authorize the other. Configure both records for manual release and leave approved
versions held. `v{version}` does not exist yet.

If Apple requests a metadata-only correction, fix only that platform's record. If Apple requests a
code change, return to Mode B and respin all three artifacts. Never substitute a newer unsoaked
build.

## C5. Create the shipped tag after review approval and final go

Wait until both App Store submissions have code approval and the user gives the final coordinated
go decision. Then create `v{version}` on the accepted RC commit; it triggers no build and records
the code that actually shipped. Include any accepted soak exception in the tag message.

```bash
git fetch origin --tags
rc_tag='rc/{version}-b{repoBuild}'
rc_commit=$(git rev-list -n1 "$rc_tag")
git tag -a 'v{version}' -m 'Release v{version} — shipped RC '"$rc_tag" "$rc_commit"
git push origin 'refs/tags/v{version}'
```

Keep every `rc/*` tag. They are the audit trail of the candidates, including the ones that were
replaced.

If `git fetch origin --tags` reports `! [rejected] ... (would clobber existing tag)`, a local tag
has drifted from the remote. The remote is authoritative for released tags: inspect both sides,
then realign with `git fetch origin --tags --force`.

## C6. Confirm main reflects the shipped state

A4 put the changelog section, the What's New content, and `MARKETING_VERSION` on `main` before the
cut, and the B5 merges carried each candidate's repo build across. Verify rather than redo:

- `main`'s `MARKETING_VERSION` is `{version}` on all four targets: `KeeForge`, `KeeForgeAutoFill`,
  `KeeForgeMac`, and `KeeForgeMacAutoFill`.
- `main`'s `CURRENT_PROJECT_VERSION` is the accepted `repoBuild` on all four targets, and the
  direct artifact's `CFBundleVersion` is also that `repoBuild`. Do not compare either value with
  the platform-specific TestFlight build numbers.
- `main`'s `CHANGELOG.md` has the `## v{version}` section, with an empty `## Unreleased` above it
  ready for the next cycle.

`CURRENT_PROJECT_VERSION` is **not** checked against either TestFlight number. Xcode Cloud manages
platform-specific build numbers and may override the project value. The repo value must still be
globally unique and increasing and must equal the direct build's `CFBundleVersion`; A5 and B2
guarantee that. The manifest is the authoritative mapping between the repo build, both TestFlight
numbers, and the direct artifact.

Fix any real drift with a single `-s` commit on `main`, then push.

## C7. Release the approved channels and verify production

After `v{version}` exists and both platform records are approved, manually release iOS and native
macOS at the coordinated time. Publish the verified GitHub Release/direct zip, then publish the
production Sparkle appcast last. Verify live installs, migration, AutoFill, WebDAV, channel
boundaries, and both App Store version/build numbers; preserve the completed non-secret manifest.

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
2. In `project.yml`, set `MARKETING_VERSION` to the patch version and increment the global
   `CURRENT_PROJECT_VERSION` on all four targets. Never reset it to `"1"`.
3. Add a `## v{version} ({date})` section to `CHANGELOG.md` above the previous version's section.
4. Run A3 only if the patch has a user-visible highlight worth a What's New sheet. Most patches do
   not; confirm `WhatsNewCatalog` has no case rather than shipping an empty sheet.

## D3. Gate, tag, distribute

Run A6, A7, A8, and A9 exactly as for a minor release. The KDBX gate is not optional for patches.

## D4. Shortened soak

Patch releases target **24h** instead of 48h. Every other A10 signal is measured and reported the
same way.

When the patch fixes an active crash or data-loss bug already reaching users, recommend shipping
  as soon as all A8 gates are accepted — for that class of bug, more soak time is usually worse for
users than less. Say that explicitly rather than leaving the user to infer it.

The gates themselves are still invariant 3: green, or every failure adjudicated. A patch under
time pressure is exactly when it is tempting to skip them, and exactly when a second bad build
does the most damage.

## D5. Ship

Continue with Mode C from C1, reporting against the 24h target in place of 48h.

---

# Notes

- The macOS targets ship in lockstep with iOS: all four product targets carry the same
  `MARKETING_VERSION` and globally monotonic `CURRENT_PROJECT_VERSION`, bumped together in A4/A5
  and every respin/patch.
- **One release branch covers both platforms.** `release/{major}.{minor}` is not per-platform, and
  neither is `rc/{version}-b{repoBuild}`: one candidate tag fires `ios18-rc-tests.yml`,
  `macos-rc-tests.yml`, and the Xcode Cloud RC workflow together, and the build they all test is
  the build both platforms ship. Splitting the branch would mean splitting the version numbers,
  which is the thing lockstep exists to prevent. A platform-specific fix still goes onto the shared
  release branch and respins one candidate for both.
- The two platforms diverge only at App Store Connect, which keeps a **separate version record,
  build, screenshot set, and review submission per platform**. Shipping is therefore not done when
  iOS is submitted; see the `publish-app-store-version` skill.
- The KDBX compatibility gate runs **per platform**. Run it for iOS as documented, then again with
  `KDBX_COMPAT_SCHEME=KeeForgeMac` (which switches the test target to `KeeForgeMacTests` and the
  destination to `platform=macOS`). Both must pass before external distribution, alongside all
  three cloud verdicts and local Mac smoke.
- The Mac ships through **two channels**. The Mac App Store build is the default
  (`xcodegen generate`) and is archived like the iOS app. The notarized
  Developer ID build is produced by `ci_scripts/build_mac_direct.sh`, which
  regenerates from the `project-direct.yml` overlay spec, archives, exports,
  refuses to submit anything that is unsandboxed or carries a
  `com.apple.security.cs.*` exception, notarizes, staples, and emits the appcast
  zip and writes a non-secret `direct-artifact.json` handoff record. Run it **after** the App Store
  build is cut, from the same commit, so both channels ship identical code. Obtain/export the exact
  MAS app from the accepted Xcode Cloud archive without rebuilding, and run
  `ci_scripts/verify_mac_artifact.sh` on both exact exported apps with `--architectures arm64,x86_64`
  before external distribution or direct-artifact staging. A different architecture set requires
  an explicit product decision recorded in the manifest. Only after both checks pass, use
  `ci_scripts/release_direct_artifact.sh stage` to preserve older appcast items. After both App Store
  submissions have code approval and the final go decision, create `v{version}` and use that
  companion's `handoff` command: it verifies both local and origin tags resolve to the artifact SHA,
  creates a draft GitHub Release (or safely resumes the exact expected draft), uploads only an
  absent asset, and verifies the draft asset via the GitHub API. Manually/explicitly publish the
  already-verified draft release in GitHub (no script invocation), then run the unauthenticated
  `verify-public-url`; only its evidence permits the explicit `publish-appcast`
  compare-and-swap against the staged base feed. Publication is atomic and fails on a concurrent
  feed change.
- `KeeForgeMacUITests` cannot run on a headless runner — it needs an unlocked, active login session
  — so the Mac smoke suite stays a **local** pre-release step. `.github/workflows/macos-rc-tests.yml`
  covers the Mac unit suite on each `rc/*` tag.
- `ITSAppUsesNonExemptEncryption` is declared `false` in `KeeForge/Info.plist` and
  `KeeForgeMac/Info.plist`, so App Store Connect
  does not ask the export-compliance question per build. It remains a legal declaration: if the
  app's cryptography changes materially, revisit it rather than assuming the key still applies.
