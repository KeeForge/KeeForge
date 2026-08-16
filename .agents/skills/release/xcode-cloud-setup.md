# Xcode Cloud Configuration This Workflow Depends On

One-time App Store Connect setup. Read this if archives or TestFlight uploads are not appearing as
expected, or when reconfiguring Xcode Cloud. Everything here is configured in the App Store Connect
web UI; none of it lives in this repo.

## Required workflow shape

| Trigger | Workflow | Actions |
| --- | --- | --- |
| `rc/*` tag push | **Tests (RC)** | Test - iOS (Required to Pass) + Archive - iOS (Distribution Preparation: App Store Connect) |
| `v*` tag push | *(none — the `Release` workflow is deactivated)* | — |

Two properties matter:

1. **Test and archive live in the same workflow, and the test action is Required to Pass.** App
   Store Connect lists a workflow's actions alphabetically and offers no way to reorder them, so
   "test first" is not something you configure — and the two actions in fact run **in parallel**.
   What Required to Pass buys is that a red test action fails the *build*, and post-actions do not
   run on a failed build. So the gate sits on **TestFlight distribution, not on the archive**: an
   archive whose tests failed can still finish and upload, and `TestFlight External Testing` then
   shows *Did Not Run*. That is the observed behavior, not a theory — `rc/1.11.0-b2` uploaded build
   38 with its test action red and never reached a tester.

   Leaving the archive ungated is deliberate. When a cloud test failure turns out to be a flake
   (`gate-adjudication.md`), the binary already exists and can be distributed by hand; gating the
   archive would force a respin to rebuild a binary that was never at fault. Switching the test
   action to *Not Required to Pass* would remove the real gate and let a build distribute over
   failing tests. Splitting test and archive into two workflows both triggered on `rc/*` would have
   the same effect, because neither could gate the other.
2. **No workflow triggers on `v*`.** The `v{version}` tag is a record of what shipped. The App Store
   build is selected in App Store Connect from the already-uploaded TestFlight build. If a `v*`
   trigger still exists from the previous process, deactivate it (workflow `⋯` menu → **Deactivate**,
   which stops its start conditions from firing) — otherwise every ship produces a stray archive
   that nobody tested, with a build number that collides with the soaked one.

## Environment variables for the archive action

`ci_scripts/ci_pre_xcodebuild.sh` fails an archive when `DROPBOX_APP_KEY` or `ONEDRIVE_CLIENT_ID`
is missing or still a CI placeholder, rather than shipping a build with broken cloud sign-in. The
Tests (RC) workflow now archives, so **it must carry the real values**. They are set per workflow,
not per action — Xcode Cloud applies them to every action in the workflow. Add them under
**Tests (RC) → Environment → Environment Variables → Add → New Environment Variable**:

- `DROPBOX_APP_KEY` — real key, with **Secret** ("Keep value redacted") ticked
- `ONEDRIVE_CLIENT_ID` — real client ID, same

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

- The archive action's **Distribution Preparation** must be **App Store Connect** ("Eligible for
  distribution to all testers and customers"), not *TestFlight (Internal Testing Only)*.
- External delivery is a separate post-action, not a property of the archive: **Post-Actions →
  TestFlight External Testing**, with *Artifact* set to the archive action and *Groups* set to the
  public-link group. That group is currently the external group named `Test` — an internal group
  shares the name, so check the heading it sits under in TestFlight.
- Saving a workflow configured for external testing forces **Restrict Editing** on; App Store
  Connect offers only *Restrict and Save*. Afterwards only the Account Holder, Admins, and App
  Managers can change it.
- The **first build of each new marketing version** goes through Beta App Review before external
  testers can install it — budget roughly a day. Later builds of the same version normally
  distribute without re-review.
- Export compliance does not prompt (`ITSAppUsesNonExemptEncryption` in `KeeForge/Info.plist`).

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
  install. It stays a required **local** gate, run once per candidate build.
- Minimum-OS coverage: Xcode Cloud's test action can only pin the latest runtime or iOS 16.4, with
  no iOS 18.x runtime available. `.github/workflows/ios18-rc-tests.yml` on GitHub-hosted `macos-15`
  runners covers iOS 18 and the iPad regular-width lane.
