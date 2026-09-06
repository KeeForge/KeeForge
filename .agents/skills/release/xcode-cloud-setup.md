# Xcode Cloud Configuration This Workflow Depends On

One-time App Store Connect setup. Read this if archives or TestFlight uploads are not appearing as
expected, or when reconfiguring Xcode Cloud. Everything here is configured in the App Store Connect
web UI; none of it lives in this repo.

## Configured state

Configured on 2026-09-06 in the App Store Connect web UI (verify the live account before
relying on this; Apple can change the UI and the account can drift):

- KeeForge is App Store Connect app Apple ID `6759309295`. The app record now carries **both**
  the iOS and macOS platforms. Adding the platform *is* the universal-purchase action — Apple's
  own dialog reads "add platforms to an app to create a universal purchase", there is no separate
  toggle, and a platform cannot be removed afterwards. The macOS side was auto-created as
  **macOS App Version 1.0**, which does **not** match the repo's `MARKETING_VERSION`; the
  version record has to be corrected to the shipping version before a Mac build can attach to
  it. TestFlight is unaffected by that mismatch — only App Store submission is.
- The active **Tests (RC)** workflow now has four actions: **Test - macOS** (scheme
  `KeeForgeMac`, Required to Pass, Test (Use Scheme Setting), destination Mac / same OS as the
  selected macOS version), **Archive - macOS** (scheme `KeeForgeMac`, Build For *Any Mac* —
  native, not Mac Catalyst — Distribution Preparation *App Store Connect*), **Archive - iOS**,
  and **Test - iOS**. Its `rc/*` tag trigger is active and the **Release** workflow is still
  deactivated.
- **No post-actions.** The former **TestFlight External Testing - iOS** post-action was deleted,
  so neither platform auto-distributes to external testers any more. This is deliberate: every
  external distribution is now a manual decision made after the gates are accepted. Re-adding a
  post-action would undo that.
- `DROPBOX_APP_KEY` and `ONEDRIVE_CLIENT_ID` are present on **Tests (RC)** and both render as
  `••••••••••`, which is how App Store Connect displays a variable with the Secret/redaction flag
  set — a non-secret variable shows its plain value. The flag is therefore on for both. Never
  record or expose their values.
- **Restrict Editing is off.** The doc previously assumed a **Restrict and Save** control; this
  account presents a plain **Save**. Turning restriction on is a separate deliberate choice, not
  a side effect of saving.
- External groups are **KeeForge Test** (the existing iOS public-link group, 300-tester cap,
  documented below) and **KeeForge Mac Test** (created empty for the native Mac build: 0 testers,
  0 builds, no public link). Do not send the MAS build to the iOS group.

Still outstanding: the non-shipping setup RC tag that proves both archives reach their TestFlight
lists, and correcting the macOS version record. External TestFlight distribution stays manual:
after Xcode Cloud, both GitHub Actions workflows, both local KDBX gates, and local Mac smoke are
accepted, obtain explicit action-time confirmation immediately before the first Beta App Review
action (when required) and immediately before distributing each platform to its external group.

## Required workflow shape

| Trigger | Workflow | Actions |
| --- | --- | --- |
| `rc/*` tag push | **Tests (RC)** | Test - iOS + Test - macOS (both Required to Pass), and Archive - iOS + Archive - macOS (both Distribution Preparation: App Store Connect). Archives/uploads may run automatically; no external-distribution post-action is configured. |
| `v*` tag push | *(none — the `Release` workflow is deactivated)* | — |

Two properties matter:

1. **Both platform tests and both platform archives live in the same workflow, and both test
   actions are Required to Pass.** App
   Store Connect lists a workflow's actions alphabetically and offers no way to reorder them, so
   "test first" is not something you configure — all four actions run in **parallel**.
   What Required to Pass buys is that a red test action fails the *workflow's test verdict*. The
   archive can still finish and upload, but that uploaded build remains blocked from external
   distribution until the failure is adjudicated and every required gate is accepted. This applies
   independently to iOS and Mac. There is no automatic external-distribution action whose status
   could bypass that deliberate manual decision.

   Leaving the archives ungated is deliberate. When a cloud test failure turns out to be a flake
   (`gate-adjudication.md`), the binary already exists and can be distributed by hand; gating the
   archive would force a respin to rebuild a binary that was never at fault. Switching either test
   action to *Not Required to Pass* would remove the real gate and let a build distribute
   over failing tests. Splitting tests and archives into workflows both triggered on `rc/*` would
   have the same effect, because neither could gate the other.
2. **No workflow triggers on `v*`.** The `v{version}` tag is a record of what shipped. The App Store
   build is selected in App Store Connect from the already-uploaded TestFlight build. If a `v*`
   trigger still exists from the previous process, deactivate it (workflow `⋯` menu → **Deactivate**,
   which stops its start conditions from firing) — otherwise every ship produces a stray archive
   that nobody tested, with a build number that collides with the soaked one.

## Environment variables for the archive actions

`ci_scripts/ci_pre_xcodebuild.sh` fails an archive when `DROPBOX_APP_KEY` or `ONEDRIVE_CLIENT_ID`
is missing or still a CI placeholder, rather than shipping a build with broken cloud sign-in. Now
that the Mac archive action lives here too, **Tests (RC) must carry the real values**. They are set
per workflow, not per action — Xcode Cloud applies them to every action in the workflow. Add or
verify them under **Tests (RC) → Environment → Environment Variables → Add → New Environment Variable**:

- `DROPBOX_APP_KEY` — real key, with **Secret** ("Keep value redacted") ticked; present and
  redacted as of 2026-09-06
- `ONEDRIVE_CLIENT_ID` — real client ID, same; present and redacted as of 2026-09-06

Adding a variable only stages it; the workflow still has to be saved afterwards.

Under the previous process the `v*` Release workflow was the one that archived, so the requirement
belonged there — but in practice neither workflow ever carried the keys, and its `v*` archives
failed this check. Moving the archive to `rc/*` moves the requirement with it.

For non-archive actions, `ci_scripts/ci_post_clone.sh` falls back to CI-only placeholders so
project generation still succeeds. The Dropbox placeholder is `ciplaceholderdropboxappkey` —
alphanumerics only, because it is interpolated into the `db-$(DROPBOX_APP_KEY)`
`CFBundleURLScheme` and App Store Connect rejects underscores with ITMS-90158.
`KeeForgeTests/URLSchemeFormatTests.swift` enforces this on the built app bundle.

## TestFlight distribution

- Each archive action's **Distribution Preparation** must be **App Store Connect** ("Eligible for
  distribution to all testers and customers"), not *TestFlight (Internal Testing Only)*.
- Do **not** configure a TestFlight External Testing post-action. Xcode Cloud may archive and
  upload automatically, but a processed build is moved to external testing manually in App Store
  Connect only after Xcode Cloud, both GitHub Actions workflows, both local KDBX gates, and local
  Mac smoke are accepted. The existing iOS public-link group is **KeeForge Test**; the native Mac
  build has its own empty group, **KeeForge Mac Test**. Do not send the MAS build to the iOS group.
- After editing, verify that no external-testing post-action is present and save the workflow using
  the control App Store Connect presents. This account presents a plain **Save**; the separate
  **Restrict Editing** checkbox is off and turning it on is its own decision, after which only the
  Account Holder, Admins, and App Managers can change the workflow.
- The **first build of each new marketing version/platform** goes through Beta App Review before
  external testers can install it — budget roughly a day. Obtain explicit action-time confirmation
  immediately before submitting that first Beta App Review action, and again immediately before
  distributing the platform to its external group. Later builds of the same platform/version
  normally distribute without re-review. External distribution remains blocked until the Xcode
  Cloud, iOS GitHub Actions, and macOS GitHub Actions verdicts, both local KDBX gates, and local
  Mac smoke are accepted and the manifest maps both processed builds to the same RC SHA.
- The build declares `ITSAppUsesNonExemptEncryption=false`; verify the actual ASC record and handle any separate legal/documentation question independently with action-time owner confirmation.

## Public link settings

- The link stays **enabled permanently** and is published on `README.md`, its `docs/i18n/`
  translations, and keeforge.com: `https://testflight.apple.com/join/mPAT4f1a`. Do not disable it
  between releases. Enabled is not the same as open — Apple closes joining on its own during Beta
  App Review and when the cap is reached — so visitors will sometimes land on a closed link.
- Set a **tester cap** on the public link (group → **Public Link → Manage → Set Limit**). A few
  hundred is plenty for a first public beta and keeps feedback triageable; the hard ceiling is
  10,000 external testers. Currently set to 300.
- Two consequences of leaving it on were weighed and accepted:
  - Testers **accumulate** toward the cap and are never cleared between releases. When the group
    fills, the link stops taking new testers; raise the limit in the same sheet or remove inactive
    testers from the group.
  - Everyone who joined for one release **auto-updates into the next release's first candidate**,
    which they never opted into. Treat every `rc/*` build as reaching the whole group the moment it
    clears review, and write the **What to Test** notes for an audience that did not ask for it.
- A published link can still be closed. While the first build of a new marketing version is in Beta
  App Review, visitors see *"This beta isn't accepting any new testers right now."* Nothing is
  misconfigured — the link recovers on approval. The same string appears if the group has no
  approved build at all or the cap is full, so check the build's state and the tester count before
  touching the link settings.
- Public-link testers join without approval and Apple does not expose their email addresses. The
  only channels back to them are the per-build **What to Test** notes and
  `feedback.keeforge.com`.

## What Xcode Cloud does not cover

- `ci_scripts/run_kdbx_compatibility_gate.sh` needs `keepassxc-cli`, which Xcode Cloud does not
  install. It stays a required **local** gate per platform, run twice per candidate (iOS and
  `KDBX_COMPAT_SCHEME=KeeForgeMac`). The local `KeeForgeMacUITests/MacSmokeUITests` suite is also
  required and needs an unlocked active login session.
- Minimum-OS coverage: Xcode Cloud's iOS test action can only pin the latest runtime or iOS 16.4,
  with no iOS 18.x runtime available. `.github/workflows/ios18-rc-tests.yml` on GitHub-hosted
  `macos-15` runners covers iOS 18 and the iPad regular-width lane. The native Mac unit gate is
  covered by `.github/workflows/macos-rc-tests.yml`.
- `ci_scripts/build_mac_direct.sh` is intentionally outside Xcode Cloud. Obtain/export the exact
  MAS `.app` from the accepted Xcode Cloud archive without rebuilding, then run
  `ci_scripts/verify_mac_artifact.sh --channel mas --app <exact-mas-app> --architectures arm64,x86_64`.
  Run the direct build from the same clean RC SHA, verify its direct `CFBundleVersion` equals the
  repo build, and run the corresponding `--channel direct` verifier on its exact exported `.app`.
  Both verifiers must pass with universal `arm64,x86_64` unless an explicit product decision
  records a different architecture set. Only then stage (do not publish) its
  `KeeForge-{version}-b{repoBuild}.zip`, `direct-artifact.json`, and appcast through
  `ci_scripts/release_direct_artifact.sh stage` until the final go decision.
  After the post-approval `v{version}` tag exists, `handoff` safely creates or resumes the exact
  draft GitHub Release and verifies its asset through the API. A draft is not public: run
  `verify-public-url` after publishing it, then use `publish-appcast`'s atomic base-feed
  compare-and-swap as a separate final step.

## Candidate identity and evidence

One `rc/{version}-b{repoBuild}` tag starts the workflow. The iOS and Mac archive actions build the
four product targets from that SHA and may receive different App Store Connect TestFlight build
numbers. Match each processed build to the RC tag/SHA and record the pair in
`scratch/release-manifests/{version}-b{repoBuild}.json` along with the direct build's
`CFBundleVersion` (which equals `repoBuild`). The manifest also records all three cloud check URLs,
both KDBX log paths, local Mac smoke result, artifact hashes/signatures, and notarization ID. It
must contain no credentials, tokens, passwords, private keys, keychain profiles, or cloud secret
values. Preserve the completed non-secret manifest with the final release evidence; it is not an
App Store Connect submission and never triggers a release.
