# Direct Mac distribution

The Developer ID direct-download channel: building and verifying its artifact, the GitHub
Release/appcast handoff, and the manual Sparkle rehearsal. Read
[the shared release contract](shared.md) first; its [channel notes](shared.md#channel-notes) give
the order of operations, and [candidate.md](candidate.md#verify-all-three-artifacts-assign-the-app-store-builds-and-distribute-when-approved)
says when each command runs during a candidate. This file holds the operational detail behind those
steps. Why the Mac has two channels built from two XcodeGen specs is in
`KeeForgeMac/README.md` ("Distribution Channels"); the update trust boundary is in
`KeeForgeMac/SECURITY.md`.

## Direct-build safety contract

`ci_scripts/build_mac_direct.sh` is the only path to a direct artifact. The Mac App Store build
does **not** go through it. Its header lists the prerequisites that live outside the repo
(Developer ID certificate, profiles, the notarytool keychain profile, Sparkle feed/key settings).

### Signing settings

For local signing with installed Developer ID profiles, save private export settings as
`Configs/ExportOptions-DeveloperID.local.plist`. The script selects this gitignored file when
present. Set `method` to `developer-id`, `signingStyle` to `manual`, `signingCertificate` to the
certificate's SHA-1, `teamID` to its team, and `provisioningProfiles` to a dictionary mapping
`com.keevault.app` and `com.keevault.app.autofill` to their installed profile UUIDs. Refresh both
mappings when replacing the certificate. Copy this file alongside `BuildConfig.local.xcconfig`
into a release worktree before building. Without local export settings, the committed
`Configs/ExportOptions-DeveloperID.plist` uses Xcode automatic signing.

### Two phases

Both phases require a clean checkout exactly at `rc/{version}-b{repoBuild}` and default to
`build/mac-direct-{version}-b{repoBuild}`.

- `--archive-export` runs under `/Users/tan/src/KeeForge/scripts/with-repo-lock.sh xcode --`. It
  regenerates from `project-direct.yml`, archives and exports, restores the App Store project and
  the exact `Package.resolved` state, then atomically publishes `export-ready.json`.
- `--finalize` runs only after that ready checkpoint exists, and without the Xcode lock. It
  verifies the clean RC/tag/tree, canonical paths, and a checksum of every exported app
  file/symlink before the hardening checks, notarization, stapling, Sparkle signing, and
  `direct-artifact.json`. It captures the validated checkpoint SHA/tree before any Apple or
  Keychain wait and uses that identity for the final metadata even if the checkout later advances.
  It never runs XcodeGen or `xcodebuild`, so do not hold the Xcode lock across Apple waiting or a
  Keychain signing prompt.
- `--preflight` is offline: it covers output refusal, checkpoint publication/identity/digest
  tampering, RC identity, archive setup without a notary credential read, the clean-worktree guard,
  and `Package.resolved` restoration. It needs no Xcode, notarization, network, or Keychain access.

### Output and worktree rules

- An explicit output directory must be an absolute path naming a safe basename exactly one level
  below `${repo}/build`. Relative paths, the build directory itself, traversal, symlinks, and paths
  outside that directory are refused before any cleanup.
- The source worktree must be clean, including untracked non-ignored files, because XcodeGen uses
  folder globs. Ignored `build/` and `scratch/` outputs are allowed.
- `--archive-export` saves the exact `Package.resolved` bytes (or records that the file was
  absent), installs its EXIT restoration trap, runs normal XcodeGen on exit, restores that saved
  state, removes its validated temporary state directory, and only then publishes
  `export-ready.json`.
- The archive phase writes only `.export-ready-pending.json` until App Store project restoration
  and clean-worktree verification succeed. A failed restoration leaves only that pending
  checkpoint, which `--finalize` refuses.
- An existing `export-ready.json`, `notarization.json`, `KeeForge-*-b*.zip`, or
  `direct-artifact.json` stops a new archive before it can rearchive bytes.
- An interrupted post-notary finalization is not retried into the same candidate output. Retain its
  ZIP, `sparkle-signature.txt`, and notarization evidence, then finish metadata or handoff manually
  without rebuilding.

### Sparkle signature check

`ci_scripts/verify_sparkle_ed25519.swift APP ZIP SIGNATURE_FILE` verifies the final ZIP's Sparkle
`edSignature` against the exported app's embedded `SUPublicEDKey`. It reads no Keychain material.
The build script runs it immediately after `sign_update` saves `sparkle-signature.txt`, before
`direct-artifact.json` is written. `--self-test` runs the offline positive and changed-archive
negative fixture.

### ZIP extraction verification

Verify the delivered ZIP as well as the exported `.app`. Inline AppleDouble `._name` entries
produced by `ditto` can become real files inside signed bundles when extracted with plain `unzip`
or third-party tools. That is unsealed content, so Gatekeeper rejects the app the user downloaded
while the exported `.app` on the build machine still passes. Apple's extractors may consume these
entries, hiding the problem during an update rehearsal.

`build_mac_direct.sh` packages with `ditto -c -k --sequesterRsrc --keepParent`, keeping resource
metadata in a `__MACOSX` sidecar. After stapling and final packaging, it extracts the ZIP with
plain `unzip` and fails closed unless all three hold:

- No AppleDouble `._*` files inside the extracted app.
- Gatekeeper acceptance of the extracted app.
- A valid stapled ticket, checked with `xcrun stapler validate`.

Keep this round trip in the build gate and keep rehearsal step 6 below as a separate clean-account
check. Do not repair, re-sign, or repackage a downloaded candidate to make that check pass; any
changed bytes need a new candidate.

## Artifact verification

`ci_scripts/verify_mac_artifact.sh` is a fail-closed, artifact-level check for an already exported
`.app`. It does not build, sign, notarize, contact Apple, or read a private key. Run it against the
exact exported app, never an archive payload substitute. For every release candidate, obtain the
exact MAS `.app` by exporting the accepted Xcode Cloud MAS archive; do not rebuild it. Run both
invocations before any external distribution or direct-artifact staging:

```bash
ci_scripts/verify_mac_artifact.sh --channel mas --app <exact-exported-mas-app> \
  --architectures arm64,x86_64 --expect-version {version} --expect-build {macTestFlightBuild}
ci_scripts/verify_mac_artifact.sh --channel direct --app <exact-direct-app> \
  --architectures arm64,x86_64 --expect-version {version} --expect-build {repoBuild}
```

Both must report `result=pass`. The other reported values must be:

| Value | MAS | Direct |
| --- | --- | --- |
| `sparkle_present` | `false` | `true` |
| `feed_url_present`, `public_update_key_present` | `false` | `true`, with an HTTPS `feed_url` |
| `storekit_bundle_present` | `false` | `false` |
| `storekit_linked` | `true` (the system framework) | `false` |
| `installer_launcher_service` | `false` | `true` |

The architecture argument is intentional: use universal `arm64,x86_64` unless an explicit product
decision records a different set before continuing.

What the verifier checks, beyond version/build and the values above:

- Code signature, hardened runtime, sandbox, nested executable bundles, channel framework/linkage
  boundaries, and exact architectures.
- The sandbox exceptions the update channel depends on. Nothing earlier in an update fails without
  them: the feed fetch, download, and EdDSA check all succeed and only the install step is
  unreachable. A direct artifact must set `SUEnableInstallerLauncherService`, carry mach-lookup
  exceptions for its own `-spks` and `-spki` names, and keep Sparkle's XPC services inside
  `Sparkle.framework` rather than in `Contents/XPCServices`. A MAS artifact must carry no
  `temporary-exception` entitlement at all and must not enable the service.
- Architecture equality across the root app and the KeeForge-owned AutoFill `.appex` executables.
- Direct StoreKit linkage across every Mach-O binary outside Sparkle's own framework/helpers, so a
  nested app cannot hide an accidental StoreKit dependency and Sparkle's legitimate updater helpers
  do not create a false positive.

## Direct artifact handoff

After the MAS archive and direct build are accepted, the direct build directory contains
`direct-artifact.json`. Its non-secret fields include the version/build, source commit and tree
SHA, exact zip name/path, SHA-256, byte size, notarization submission ID, Sparkle enclosure
attributes, and archive/symbol paths.

`ci_scripts/release_direct_artifact.sh` performs every step below. `generate_appcast.py` is its
deterministic, standard-library appcast builder: it inserts the new signed item ahead of older
items and rejects a duplicate version/build. Each new item's `sparkle:releaseNotesLink` is the
version's GitHub release page, `https://github.com/KeeForge/KeeForge/releases/tag/v{version}`.

### Stage (candidate time)

```bash
ci_scripts/release_direct_artifact.sh stage \
  --artifact-json build/mac-direct-{version}-b{repoBuild}/direct-artifact.json \
  --output-dir scratch/direct-release \
  --input-appcast /path/to/current-appcast.xml
```

`stage` validates the build JSON, preserves older appcast items, and records the base-feed SHA (or
its explicit absence) and the staged-feed SHA in `staged-appcast.json`.

Use `--new-feed` only when the production endpoint is actually absent. KeeForge's production
`https://keeforge.com/appcast.xml` already exists and must be downloaded as the input so each new
item preserves every published release. Never use a prior candidate's staged file. The stage output
is immutable: choose a fresh directory for a respin.

### Handoff (after approval and final go)

Only after both App Store submissions have code approval and the final go decision, create the
post-approval `v{version}` tag and run `handoff` with the same artifact JSON, stage directory, and
base feed, plus the reviewed release body:

```bash
ci_scripts/release_direct_artifact.sh handoff \
  --artifact-json build/mac-direct-{version}-b{repoBuild}/direct-artifact.json \
  --output-dir scratch/direct-release \
  --notes-file /path/to/reviewed-release-notes.md \
  --input-appcast /path/to/current-appcast.xml
```

- It requires local **and origin** `v{version}` and `rc/{version}-b{repoBuild}` tags to resolve to
  the artifact's commit SHA before calling `gh`.
- It resumes the existing stage only when its identity and base feed match exactly.
- It creates a new draft release and uploads the exact `KeeForge-{version}-b{repoBuild}.zip` once.
  If a prior run already created the draft, only that exact draft is resumed: an absent asset is
  uploaded once, while a present asset is downloaded through `gh api` and verified without
  clobbering. A published or mismatched release, or an unexpected asset, fails closed.
- It never publishes the appcast.

### Publish (explicit, last)

A draft release is not a public URL. Publish the release manually/explicitly in GitHub; there is no
script invocation for this promotion. Then run the unauthenticated `verify-public-url` and retain
its SHA/size evidence, and only then `publish-appcast` with the staged metadata, the public
evidence, and an explicit deployment destination:

```bash
ci_scripts/release_direct_artifact.sh verify-public-url \
  --artifact-json build/mac-direct-{version}-b{repoBuild}/direct-artifact.json \
  --output scratch/direct-release/public-verification.json
ci_scripts/release_direct_artifact.sh publish-appcast \
  --staged scratch/direct-release/appcast.xml \
  --metadata scratch/direct-release/staged-appcast.json \
  --public-verification scratch/direct-release/public-verification.json \
  --destination /path/to/deployed/appcast.xml
```

`publish-appcast` requires the public evidence, then performs an atomic compare-and-swap: for a
first feed it requires the destination to still be absent; otherwise the destination's current
bytes must match the staged base SHA immediately before an atomic rename. It will not overwrite an
unrelated or concurrently changed feed. Never use `--clobber`, replace a mismatched release/asset,
or publish a feed without final public URL verification.

Check the live feed before publication (it must match the recorded base) and after (it must match
the staged feed); the evidence file's `matches` field says which one was seen:

```bash
ci_scripts/release_direct_artifact.sh verify-live-feed \
  --metadata scratch/direct-release/staged-appcast.json \
  --url https://keeforge.com/appcast.xml \
  --output scratch/direct-release/live-feed.json
```

The website source is `keeforge.com/public/appcast.xml`. Pages deploys when its reviewed source
change is pushed, then the Worker serves it at `/appcast.xml`.

### Offline rehearsal

The normal test path, safe to run at any time:

```bash
ci_scripts/release_direct_artifact.sh --fixture "$(mktemp -d)"
```

The fixture keeps an older item, checks the release-notes link, creates a deterministic zip,
validates its hash/size, verifies the local download through the same byte-check abstraction used
for GitHub assets, exercises duplicate and base-mismatch refusal, and atomically publishes against
a matching local base. It does not invoke `gh`, `curl`, `xcodebuild`, `notarytool`, tags, pushes,
or App Store Connect.

## Manual Sparkle rehearsal (test feed only)

Run this on a disposable Mac or test account after changing the feed host, signing key, updater
configuration, release handoff, or Sparkle sandbox exceptions. `KeeForgeMac/SECURITY.md` ("Sparkle
update trust") describes the trust boundary; this procedure verifies an actual update. It does not
authorize production publication. Use the Xcode lock wrapper for local Mac app runs as required by
the repository's local instructions.

1. Confirm that an off-machine recovery copy of the Sparkle EdDSA private key is backed up. Record
   only that the prerequisite was confirmed, never the key or its location. Do not generate,
   export, or print the private key during the rehearsal. Prepare older and newer notarized,
   stapled direct-download apps using the same key pair and architecture set (normally
   `arm64,x86_64`). Configure the older build's `SUFeedURL` for the isolated test feed before
   signing and notarization; do not edit a signed app's plist.
2. Prepare an isolated HTTPS test host, using a temporary hostname or a local TLS service with a
   trusted certificate. Create a test appcast containing only the newer build. Sign the exact newer
   ZIP with Sparkle's `sign_update` using the login Keychain key; put only the public
   `sparkle:edSignature` and byte `length` in the enclosure. Never point this rehearsal at the
   production `https://keeforge.com/appcast.xml` feed. Keep vault passwords and tokens out of
   commands, appcasts, screenshots, and logs.
3. Install the older app from its notarized ZIP in the test account and run
   `ci_scripts/verify_mac_artifact.sh --channel direct --app <older-app> --architectures arm64,x86_64`
   (substitute the explicitly agreed architecture set if different). Open a disposable copy of a
   test vault and leave it visibly unlocked while checking for updates. Confirm that Sparkle
   downloads the exact newer ZIP, verifies the signature, replaces the app, and encounters no
   sandbox or hardened-runtime failure.
4. After relaunch, confirm that the newer version is running and the vault is locked. Unlock must
   be required again: no unlocked session may survive the updater restart. Reopen the disposable
   vault and verify it still reads.
5. Make a separate copy of the newer ZIP, alter one byte, and serve that copy at the test enclosure
   URL without changing its signature or length. Start again from the older app. Sparkle must
   reject the download and leave the older app installed and running, with no successful
   installation reported. Restore the exact signed ZIP afterward; never alter the accepted release
   artifact itself.
6. Download the exact signed ZIP afresh in a clean account, preserve the browser's quarantine
   attribute, and launch the extracted app without clearing quarantine. Confirm that Gatekeeper
   accepts it and that `verify_mac_artifact.sh` still passes. Record the artifact identities and
   non-secret results in the candidate manifest, then remove the disposable app, test feed, vault
   copy, and temporary logs after retaining the required evidence.

A static artifact-verifier pass cannot replace the successful-update, altered-download rejection,
locked-relaunch, and clean-account launch checks. Old successful rehearsals are not evidence for
changed update infrastructure.
