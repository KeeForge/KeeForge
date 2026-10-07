# Build and distribute a candidate

Read [the shared release contract](shared.md) before running this procedure. Run build-number
selection once per candidate, including when reached from patch or respin preparation.

## App Store Connect build-number preflight

For every new or replacement candidate, perform this read-only check immediately before
changing `CURRENT_PROJECT_VERSION`:

1. Use browser control to open the signed-in App Store Connect website, then navigate to
   **Xcode Cloud → KeeForge product → Settings → Build Number**. Do not use TestFlight upload
   history, the latest build page, a local tag, or a remembered value as a substitute.
2. Read the integer displayed under **Next Build Number** and call it `xcodeCloudNextBuild`. This is
   the product-wide counter shared by the KeeForge Xcode Cloud workflows, not an iOS-only or
   macOS-only value. Record the page URL, observation time, displayed value, and screenshot or
   equivalent browser evidence before editing the project. Carry this non-secret evidence into the
   candidate manifest after [RC tag and manifest](candidate.md#commit-push-and-tag-the-candidate) initializes it.
3. If App Store Connect is inaccessible, the signed-in product cannot be identified, or the value
   is absent, nonnumeric, or ambiguous, stop. Do not calculate a replacement from upload history or
   continue with only the repository value.
4. Return to the applicable [build-number selection](candidate.md#set-the-candidate-build-number), [Bump the build number](../../respin-release/SKILL.md#bump-the-build-number), or [Land the fix and bump](patch.md#land-the-fix-and-bump) candidate step and compare this displayed value with the
   repository floor before editing the project.

If any unrelated Xcode Cloud run starts between this observation and the RC tag push, refresh this
page and repeat the preflight before committing the candidate. Record the actual iOS and macOS
uploaded build records later in [artifact verification and beta distribution](candidate.md#verify-all-three-artifacts-assign-the-app-store-builds-and-distribute-when-approved); the preflight value is authoritative for `repoBuild`, but it is
not a substitute for verifying the binaries Xcode Cloud actually produced.

Reference files, read on demand:

- [gate-adjudication.md](gate-adjudication.md) — how to read cloud check runs and adjudicate test failures locally.
  Read this whenever a cloud gate is not green in [candidate gates](candidate.md#wait-for-all-cloud-gates-and-local-mac-smoke); apply the same test-vs-infrastructure
  distinction to the macOS workflow and never override a non-test failure with a local pass.
- [xcode-cloud-setup.md](xcode-cloud-setup.md) — the one-time App Store Connect workflow configuration this process
  depends on. Read it if archives or TestFlight uploads are not appearing as expected.

## Set the candidate build number

Determine the repository floor mechanically; never use the App Store Connect result or a single
working-tree value as the only source. The new four-target invariant begins with this process:
older revisions may predate the Mac targets and may contain unequal or reset build values. Scan
those revisions for every numeric value belonging to whichever of the four targets existed, using
their maximum only as the legacy floor. Separately require the current working tree to satisfy the
new invariant. First fetch the refs used for release bookkeeping, then validate every present
new-process manifest. Run this in a fresh Bash shell; any failed check is a stop, not a reason to
fall back to a guessed value:

```bash
git fetch origin --tags 'refs/heads/release/*:refs/remotes/origin/release/*'
ci_scripts/next_repo_build.sh --no-fetch
```

Call the script's reported value `localNextBuild`. Complete the App Store Connect build-number
preflight above, require `xcodeCloudNextBuild >= localNextBuild`, and set `repoBuild` to exactly
`xcodeCloudNextBuild`. State both values and their evidence. Never derive `repoBuild` by incrementing
the latest upload or by taking a maximum without reading the Xcode Cloud Build Number page. A
higher Xcode Cloud value may intentionally skip unused repository numbers. If it is lower than
`localNextBuild`, stop: do not silently take the maximum. The owner may explicitly authorize using
**Edit** on the same page to raise the counter to `localNextBuild`; after any edit, read the page
back and record the new displayed value before continuing.

Stop if the current `project.yml` does not contain exactly one numeric
`CURRENT_PROJECT_VERSION` for each of `KeeForge`, `KeeForgeAutoFill`, `KeeForgeMac`, and
`KeeForgeMacAutoFill`, or if those four current values differ. Historical revisions are not required
to satisfy this new invariant: absent Mac targets, unequal values, and old resets are tolerated, but
only numeric values from an existing target contribute to the legacy floor. Stop if a present
new-process manifest is malformed/missing `repoBuild`, or if its `repoBuild` disagrees with its
filename/RC tag. The greatest validated value across reachable project history and manifests is the
previous global maximum; its successor is `localNextBuild`. Set the selected `repoBuild` on all
four current targets. Re-check that all four current values are identical before committing and
record the result plus the App Store Connect preflight in the new manifest. A missing project
history or no usable numeric historical value is not evidence that the floor is zero; stop and
resolve the scope instead. A manifest from a different release may legitimately have a lower build;
only malformed or internally inconsistent evidence is a disagreement.

`MARKETING_VERSION` must already match the selected new, patch, or respin version.

## Regenerate and run the local KDBX gate

```bash
xcodegen generate
```

Run the KDBX compatibility gate twice in a fresh `bash` session, under the repo's Xcode lock. Both
are required for **every candidate build** — Xcode Cloud does not install KeePassXC, so the release
machine is the only place KeeForge-written databases are cross-validated against another KeePass
implementation:

```bash
LOG=/Users/tan/src/KeeForge/scratch/xcode-logs/$(date +%Y%m%d-%H%M%S)-kdbx-gate-ios.log
mkdir -p "$(dirname "$LOG")"
KDBX_COMPAT_RESULT_BUNDLE="$PWD/build/kdbx-gate-ios.xcresult" \
KDBX_COMPAT_ATTACHMENTS_DIR="$PWD/build/kdbx-gate-ios-attachments" \
/Users/tan/src/KeeForge/scripts/with-repo-lock.sh xcode -- \
  ci_scripts/run_kdbx_compatibility_gate.sh > "$LOG" 2>&1
echo "exit=$? log=$LOG"
```

Repeat with `KDBX_COMPAT_SCHEME=KeeForgeMac`, a separate `-mac` log, and separate
`kdbx-gate-mac` result bundle and attachments paths — the script deletes its result bundle and
attachments directory before each run, so shared defaults would erase the iOS evidence. Record
both verdicts, logs, and result bundles as `gates.kdbxIOS` and `gates.kdbxMac`.

If `keepassxc-cli` is not installed, stop and ask the user to install KeePassXC (or point
`KEEPASSXC_CLI` at the binary). Do not skip this gate or proceed past a failure.

Do **not** run the full unit or UI suites locally here — the cloud systems run them in [candidate gates](candidate.md#wait-for-all-cloud-gates-and-local-mac-smoke). The
required local Mac smoke and the focused pre-commit What's New preview are the UI exceptions.

## Commit, push, and tag the candidate

Verify that the [release-content preview](shared.md#release-content-preview-before-commit)
copy approval and screenshot confirmation cover all release content in this candidate. Any changed
copy or rendering must be re-approved before this commit; unchanged approved content can be reused.

1. Stage the changed files. For a new minor/major release, the changelog and What's New content already landed on `main`;
   its first candidate normally only carries the build bump and regenerated project.
   Patch candidates must also stage their versioned changelog and any changed What's New files:
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

Create the immutable candidate record now, after the RC tag exists. It records no secrets and
refuses to overwrite an earlier candidate with the same identity. Do not validate distribution
evidence yet: [candidate gates](candidate.md#wait-for-all-cloud-gates-and-local-mac-smoke) and [artifact verification and beta distribution](candidate.md#verify-all-three-artifacts-assign-the-app-store-builds-and-distribute-when-approved) are what produce it.

```bash
ci_scripts/candidate_manifest.py init --rc-tag rc/{version}-b{repoBuild}
```

The tag push triggers Xcode Cloud's RC workflow (iOS tests plus iOS and Mac App Store
archives/uploads), `.github/workflows/ios18-rc-tests.yml`, and `.github/workflows/macos-rc-tests.yml`.
Xcode Cloud has no Mac test action (see [xcode-cloud-setup.md](xcode-cloud-setup.md)); the Mac unit suite runs only in
`macos-rc-tests.yml`. If Xcode Cloud shows no run for the tag, follow "Recovering a missing
tag-triggered run" in [xcode-cloud-setup.md](xcode-cloud-setup.md); never move or re-create the RC tag to retrigger it.

## Wait for all cloud gates and local Mac smoke

The RC tag starts three cloud verdicts. All three, plus the two KDBX verdicts from [local KDBX gates](candidate.md#regenerate-and-run-the-local-kdbx-gate) and the
local Mac smoke suite, must be accepted before either App Store build is distributed to external
testers or the direct build is called a release candidate.

1. Monitor Xcode Cloud through GitHub — it mirrors onto the RC commit as check runs for Test -
   iOS and both archive actions:
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
   An automatic GitHub test-gate pass requires its uploaded canonical `.xcresult` summary to report
   `result=Passed`, zero failures, and at least one executed test; exit 65 is accepted only then.
   Canonical XCTest failures, including ones behind a green console summary, require the exact
   [gate-adjudication.md](gate-adjudication.md) path. Any other nonzero `xcodebuild` exit or a missing/malformed result
   bundle is a failed non-test gate and cannot be adjudicated.
5. Run `KeeForgeMacUITests/MacSmokeUITests` locally on an unlocked release Mac under the repo
   Xcode lock, following the [owner-readiness preflight](shared.md#candidate-owner-readiness). The harness
   can touch live App Group/defaults state. This is an explicit before/after
   operation, not a shell `trap`: do not restore while an app or UI-test process may still be running.
   The helper is fixed to `group.com.keevault.shared` and `com.keevault.app`, and accepts state roots
   only directly under `scratch/release-session`.

   When driving this multi-step native UI sequence through Codex tools, keep a single supervised
   `/Users/tan/src/KeeForge/scripts/with-repo-lock.sh xcode -- bash` session open from the backup
   through restoration. Allocate a PTY (`tty: true`) and send every command through that retained
   execution session. Exit or interrupt it only after
   restoration completes so the wrapper releases the lock. Do not use the detached `acquire` mode
   here: Codex cleans up its detached holder when the acquire call finishes.

   ```bash
   osascript -e 'tell application "KeeForge" to quit' 2>/dev/null || true
   pkill -f 'KeeForgeMacUITests-Runner' 2>/dev/null || true
   STATE_ROOT="$PWD/scratch/release-session/pre-ui-state-b{repoBuild}"
   ci_scripts/restore_pre_ui_state.sh --state-root "$STATE_ROOT" --backup
   # Run the UI smoke here. Keep STATE_ROOT for review.
   osascript -e 'tell application "KeeForge" to quit' 2>/dev/null || true
   pkill -f 'KeeForgeMacUITests-Runner' 2>/dev/null || true
   ci_scripts/restore_pre_ui_state.sh --state-root "$STATE_ROOT"
   ci_scripts/restore_pre_ui_state.sh --state-root "$STATE_ROOT" \
     --execute --confirm RESTORE_PRE_UI_STATE
   ```

   `--confirm` is an accidental-invocation guard, not another owner decision. The helper verifies the
   pre-run manifest, preserves a private post-run backup before any write, restores original contents
   with `rsync --checksum` and no `--delete`, and restores preferences through CFPreferences. It
   records the baseline's exact OS-created Application Scripts group link by literal path and target
   without dereferencing it when present; any other or changed link stops safely, while a missing
   live copy is restored when recorded in that verified backup. It stops with both backups
   preserved for an absent original/live App Group or any unproven extra. The sole
   removable extra is one database-cache `.kdbx` whose SHA-256 exactly matches `TestFixtures/test.kdbx`.
   It finishes only after original hashes, semantic defaults equality, and the no-extra comparison pass.
6. If any cloud gate is not green, **read [gate-adjudication.md](gate-adjudication.md)** and follow it. Do not distribute
   a build whose gates are unresolved; a local pass cannot override a non-test infrastructure
   failure.

Xcode Cloud's test and archive actions run in parallel. A red test action may still upload a build,
but that build remains blocked from external distribution until the failure is adjudicated and all
required gates are accepted. External TestFlight distribution is always a deliberate manual action
in App Store Connect, independently for iOS and Mac.

## Verify all three artifacts, assign the App Store builds, and distribute when approved

1. Find both processed builds in App Store Connect under TestFlight for marketing version
   `{version}`. Their numbers may differ from `repoBuild` and from each other because Xcode Cloud
   assigns platform-specific numbers. Match each build to the `rc/{version}-b{repoBuild}` tag and
   SHA, then record `iosTestFlightBuild` and `macTestFlightBuild` in the manifest. Verify export
   compliance on each actual platform record; do not assume the plist declaration resolves every
   legal or documentation question (see [channel notes](shared.md#channel-notes)). When adding a build to an external group, choose
   its platform explicitly: the picker can default to iOS even in the Mac group. Match the
   platform's manifest `buildID` as well as its version and build number, which may be identical
   across iOS and macOS.
2. Obtain/export the exact MAS `.app` from the accepted Xcode Cloud archive without rebuilding.
   Stay in App Store Connect's built-in browser; do not use `curl` or an API download. If the
   artifact anchor's ordinary click or download capture produces no file, open its exact DOM `href`
   in a fresh built-in-browser tab. `net::ERR_ABORTED` can occur when navigation becomes a download;
   it is not proof of a completed download. Before accepting it, verify the new file's name, byte
   size, and SHA-256 on disk, then
   close any temporary `about:blank` tabs.
   Run the artifact check on that exact exported app:
   ```bash
   ci_scripts/verify_mac_artifact.sh --channel mas --app <exact-exported-mas-app> \
     --architectures arm64,x86_64 --expect-version {version} --expect-build {macTestFlightBuild}
   ```
   Do not substitute an embedded archive app: the exact exported package can have its own build
   number. The expected architecture set is the
   universal `arm64,x86_64`; a different set requires an explicit product decision recorded in the
   manifest before continuing.
3. Run the direct archive/export from the same clean RC SHA under the global Xcode lock. It restores
   the App Store project before returning success and publishes `export-ready.json` only after that
   restoration is clean. Then finalize that exact checkpoint without the Xcode lock; finalization
   never regenerates or rebuilds the app, so an Apple wait or Keychain signing prompt cannot block
   other Xcode work. Follow the [owner-readiness preflight](shared.md#candidate-owner-readiness) if `sign_update` requests Keychain
   authentication:
   ```bash
   /Users/tan/src/KeeForge/scripts/with-repo-lock.sh xcode -- \
     ci_scripts/build_mac_direct.sh --archive-export --rc-tag rc/{version}-b{repoBuild}
   ci_scripts/build_mac_direct.sh --finalize --rc-tag rc/{version}-b{repoBuild}
   ```
   The finalize phase captures the validated checkpoint's tag/SHA/tree before notarizing, so its
   final metadata stays bound to that RC through Apple and Keychain waits. It also verifies canonical
   paths and the exported-app digest. Verify its direct `CFBundleVersion` equals the repo build and run the
   same fail-closed check on its exact exported app:
   ```bash
   ci_scripts/verify_mac_artifact.sh --channel direct --app <exact-direct-app> \
     --architectures arm64,x86_64 --expect-version {version} --expect-build {repoBuild}
   ```
   Both artifact checks must pass before any external distribution or direct-artifact staging.
   Then run `ci_scripts/release_direct_artifact.sh stage` to generate a complete unpublished appcast
   while preserving older items and recording the base-feed hash. Do not run `handoff` until [production publication](../../ship-release/SKILL.md#release-the-approved-channels-and-verify-production)'s
   post-approval go decision.
   Before distributing either beta, add all three verified artifact identity records under
   `artifacts` in the candidate manifest. Each accepted/adjudicated gate and artifact must carry
   the RC commit/tree; bind iOS and MAS TestFlight build IDs to their platform records. The direct
   record must be the generated metadata for its exact ZIP, including matching hash, size,
   notarization, and Sparkle attributes. Then validate the complete distribution evidence:
   ```bash
   ci_scripts/candidate_manifest.py validate \
     --manifest scratch/release-manifests/{version}-b{repoBuild}.json --mode distribute
   ```
4. Write platform-specific **What to Test** notes for each build. These are the only text each
   tester group sees, and are the steering channel for the soak. Always include:
   - What changed in this build, in user terms.
   - **"Test against a copy of your database, not your primary vault."** A TestFlight build shares
     the production bundle ID and container, so testers are running an unreviewed candidate
     against their real KDBX files.
   - Any area you specifically want exercised.
   The current macOS public TestFlight link is `https://testflight.apple.com/join/ZKQRwPaa`; record
   its enabled state in the manifest instead of treating the link itself as distribution evidence.
5. If this is the **first build of this marketing version/platform**, submit it for Beta App Review
   when the user has already authorized that named candidate submission; otherwise obtain a
   confirmation at this action. Later builds of the same version normally skip it. Do not announce a ship
   date until this clears. Until it does, the published public link shows
   *"This beta isn't accepting any new testers right now"* to everyone arriving from `README.md`
   or keeforge.com — expected, and another reason not to announce early.
6. Assign **both** App Store builds to their platform-specific external TestFlight groups immediately
   after step 5 — or immediately after the notes for a later build that skips Beta App Review. Do
   this even when the review state is `READY_FOR_BETA_SUBMISSION`, `WAITING_FOR_REVIEW`, or
   `IN_REVIEW`; do not wait for `APPROVED`. Assign the exact iOS build ID to the iOS external group
   and the exact macOS build ID to the Mac external group; never cross-assign them just because the
   visible version/build numbers match. This early association is intentional: App Store Connect
   keeps an unapproved build unavailable to external testers, then makes the already-associated
   build available after approval without a later manual add that can be forgotten.

   When the user has already authorized distribution of that named candidate, the authorization
   covers these two group assignments; otherwise obtain confirmation immediately before the first
   group mutation. Do not treat beta authorization as production go or a legal declaration. Read
   both group relationships back and record each `groupID`, `buildID`, review state, and
   `groupAssignmentTimestamp` in the manifest. The iOS public link is permanently enabled, so once
   approved, distribution reaches every tester accumulated from earlier releases, not just people
   who opted into this one.
7. Track group assignment separately from actual distribution. A pending build's
   `groupAssignmentTimestamp` is **not** its soak start: leave `distributionTimestamp` unset until
   App Store Connect reports that the exact associated build is externally available (for example,
   `externalBuildState` is `IN_BETA_TESTING`). Record that observed distribution timestamp for each
   platform; its soak clock starts there, not at assignment, review submission, or branch cut. The
   direct artifact has no TestFlight metrics and is tested separately in [soak guidance](soak.md#candidate-soak).
