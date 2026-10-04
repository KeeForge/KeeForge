---
name: publish-app-store-version
description: Prepare and publish an already-built KeeForge iOS or macOS version through the App Store Connect API using an API key. Use for uploaded-build selection, localized listing and release notes, reviewer attachments, release settings, and App Review staging or submission. Do not use for version bumps, release candidates, tags, compatibility gates, or archive creation; use prepare-release or respin-release for candidates, and ship-release for coordinated production publication.
---

# Publish KeeForge App Store Version

## Scope and authorization

Use the documented App Store Connect REST API at `https://api.appstoreconnect.apple.com`
with API-key authentication. No signed-in browser, session cookies, or private website APIs are
required. If an operation is unavailable through the public API or the key lacks permission,
report the specific blocker. Do not silently switch to browser automation or broaden key access.

Operate only on the requested platforms and fields. Prepare localization, attachment, and review-draft writes within the authorized scope.
Show the English release-note draft before saving public copy unless already approved.
Retain the version-creation and final-submission confirmation boundaries below.

Staging ends before final submission. `PATCH /v1/reviewSubmissions/{id}` with
`submitted: true` sends the contents to Apple; it is not a validation or staging request. Obtain
a separate explicit action-time confirmation immediately before each platform's final submission,
naming its exact version and build. Approval for iOS does not imply approval for macOS. A request
to prepare everything before submission authorizes neither submission nor production release.
Never use the legacy `appStoreVersionSubmissions` POST as a way to stage a draft.

Beta App Review, external TestFlight distribution, production submission, production release,
and legal declarations are separate actions. Perform them only within the user's explicit
scope. Do not add a platform, change purchase configuration, or change availability as a side
effect of publishing an existing platform.

## Credentials stay local

Read applicable private local guidance for credential discovery. Otherwise use configured
environment variables or a user-specified private environment file:

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID` for a team API key
- `APP_STORE_CONNECT_KEY_PATH` for the private `.p8` key

The public skill must contain no actual key or issuer IDs, credential filenames, personal
filesystem paths, reviewer contact details, or tokens. Keep machine-specific discovery paths
in private, Git-excluded local guidance. Do not copy the credentials into this skill, scratch
artifacts, release manifests, issues, commits, or terminal output. Parse an environment file
as data; do not execute its contents. Resolve configured home-relative paths in process.

Generate a short-lived ES256 JWT using an established library such as PyJWT with cryptography.
For a team key use `iss`, `iat`, `exp`, and `aud: appstoreconnect-v1`; header fields are
`kid`, `typ: JWT`, and `alg: ES256`. A two-minute lifetime suits a preflight; keep other tokens
at or below 20 minutes and renew during longer work. Individual keys use `sub: user` instead
of `iss`; confirm key type rather than guessing from a missing issuer.

Keep the key and JWT in memory. Send the bearer token only to the API origin above. Do not put
it in process arguments, shell traces, HTTP debug output, or a printed request object. Disable
automatic redirects for authenticated requests. Upload URLs have their own authorization and
must not receive the ASC bearer token.

Start with a read-only app lookup to verify authentication and app identity. A successful GET
proves read access only, not permission to submit or release. For `401`, check token expiry,
clock, and configured key type; for `403`, report the missing permission without changing roles.

See [API operations](references/api-operations.md) for endpoints, JSON:API request shapes,
upload handling, and current Apple documentation. Verify the current documented schema before
using a field not covered there.

## Release inputs and platform identity

KeeForge has one app record with separate `IOS` and `MAC_OS` versions, builds, localizations,
screenshots, and review submissions. Resolve the app from the handoff or the repository's main
bundle identifier, then confirm its identity. Do not select an app by display name alone.

The `prepare-release` and `respin-release` skills prepare the candidate; after soak,
`ship-release` hands off the accepted release manifest. Require that handoff at
`scratch/release-manifests/{version}-b{repoBuild}.json`. Match the marketing version, repo build,
RC tag/SHA, `iosTestFlightBuild`, `macTestFlightBuild`, and platform build IDs. Both builds must
come from the accepted RC; `directCFBundleVersion` must equal `repoBuild`. Verify the recorded
external TestFlight soak and direct-channel evidence. Internal-only testing and Xcode Cloud
upload success do not establish an accepted external soak.

The direct-download Mac artifact is outside this skill: verify its handoff evidence but never
upload, notarize, rebuild, or release it here. Select the existing accepted App Store builds;
never substitute the newest build, trigger CI, bump versions, or make an archive. If a required
manifest mapping or build is missing, stop and report it. An existing upload may still be
processing; bounded polling is allowed, but do not wait for an unrequested new build.

For a narrowly requested listing correction or read-only investigation, inspect the specified
record without requiring a release manifest. That scope does not authorize changing its build,
staging a different candidate, or submitting it.

Other inputs:

- Read only the requested version's `CHANGELOG.md` section, never `Unreleased`.
- Preserve existing reviewer notes and contact details unless incorrect. The disposable reviewer
  fixture is `test.kdbx.zip`, with password `testpassword123`; resolve its local source from
  private guidance or user input. Never substitute a personal database.
- For Mac listing/reviewer copy, read [mac-listing-metadata.md](mac-listing-metadata.md).
  It is a historical saved-copy reference, not live submission or release authorization.
  Update it after an authorized Mac copy change with redacted readback evidence only.
- Enumerate each version's actual localizations; the App Store list can differ from the app's
  shipped languages. Do not assume seven locales or add a locale just because the app supports it.

## Workflow

### 1. Inspect each platform

Read the requested version, its attached build, localizations, reviewer details/attachments,
screenshot sets, release settings, availability, and existing review submissions/items. Follow
pagination, including nested relationship lists. Record only the non-secret IDs and state needed
for the task; summarize reviewer contact completeness without printing personal contact values.

Match the build's `preReleaseVersion.version` and `preReleaseVersion.platform` as well as its ID
and `build.version` (the build number). API `processingState: VALID` means processing succeeded;
it is distinct from an asset's `COMPLETE` state. Reject failed/invalid builds and
`buildAudienceType: INTERNAL_ONLY` for production. Inspect beta eligibility and the accepted
soak evidence rather than interpreting processing success as test distribution or approval.

If a version is already submitted, in review, or released, report its actual state and use only
operations valid for the requested correction. Do not cancel, withdraw, recreate, or resubmit it
to force it through the preparation path.

### 2. Create or reuse the exact version and attach its build

Reuse the matching platform/version record. If absent, confirm creation immediately before POSTing an
`appStoreVersions` resource related to the app, with the exact `platform`, `versionString`, and
intended `releaseType`. Coordinate KeeForge releases with `MANUAL` unless the owner explicitly
chooses otherwise. Check for an existing record again after an ambiguous POST outcome.

PATCH the version's `build` relationship with the exact manifest build ID. GET that relationship
and build afterward and recheck the full platform/version/build mapping. If Apple rejects the
build, report the error instead of choosing another candidate.

### 3. Verify export compliance

Read the selected build's `usesNonExemptEncryption` and any associated encryption declaration.
Both app plists declare `ITSAppUsesNonExemptEncryption=false`, but that source declaration is
not proof that the selected upload has resolved compliance. Verify both platforms separately.

Do not automatically PATCH a missing declaration to `false`. New encryption answers, documents,
or France-related declarations require the exact current question/field choices and explicit
owner/legal confirmation at action time. The accepted prior record is context, not authorization
to reuse an answer. Preserve France availability unless the owner explicitly decides otherwise.
If a required legal workflow is unsupported by the public API, identify the manual action needed.

### 4. Save localized copy and verify screenshots

Draft concise user-facing release notes from the versioned changelog, mentioning minimum-OS
changes. Save approved `whatsNew` through `appStoreVersionLocalizations`; translate the same
meaning into every live locale. Keep KeeForge, KeePass, KDBX, AutoFill, WebDAV, TOTP, passkey,
and iOS recognizable. Read back each field after saving and check documented field limits.
Do not change descriptions, keywords, URLs, or other listing fields unless in scope.

Verify the version's screenshot sets and processed assets, including inherited galleries. iOS
screenshots do not satisfy macOS. When new Mac screenshots are requested, use
`KeeForgeMacUITests/MacScreenshotAuditUITests` exports and
`ci_scripts/make_appstore_screenshots.py --platform mac --input-dir <export>` for the seven
2880×1800 images; read the test folder's guidance before capturing. Upload only the appropriate
platform assets using the reservation/upload/commit protocol in the API reference.

### 5. Verify reviewer details and fixture

Read `appStoreReviewDetail`: preserve the contact fields, confirm sign-in is unnecessary for
KeeForge, and keep notes explaining how to open the attached fixture with its password. Mac
notes should describe File > Open Database and System Settings > General > AutoFill & Passwords;
iOS notes should describe its own import and AutoFill flow.

List review attachments. Reuse an existing `test.kdbx.zip` only after confirming successful asset
processing. If absent, resolve and verify the disposable fixture, reserve an
`appStoreReviewAttachments` resource, upload its exact byte ranges, commit the checksum, and
poll until `assetDeliveryState.state: COMPLETE`. A filename or successful reservation alone
is not evidence of an uploaded attachment. If the fixture is unavailable, ask for its path.

### 6. Preserve release behavior and unrelated settings

For coordinated releases, verify both version records use `releaseType: MANUAL`. Preserve any
existing phased-release configuration; create or change one only when explicitly requested.
Keep existing ratings and do not send a rating-reset operation. Preserve availability, pricing,
privacy, age ratings, and purchase configuration. If a setting cannot be verified through the
current public API, report it as unverified rather than claiming the UI-equivalent check passed.

### 7. Stage a review draft and stop

For each platform, reuse an appropriate unsubmitted `reviewSubmissions` draft, or create one
related to the app with the explicit platform. List its items before editing. Do not alter a
draft containing unrelated versions/items or combine the two platforms into one submission.

Add the exact version via `reviewSubmissionItems` only if it is not already present. Resolve
concrete validation errors within scope and read back the submission, item, version, and build.
The staging target is a `READY_FOR_REVIEW` submission with the exact version's item also
`READY_FOR_REVIEW` and no submitted date. Report the version's own state separately; it is not
interchangeable with the submission or item state. These checks cannot guarantee Apple will
accept final submission; never submit just to discover additional validation errors.

Stop here for a prepare-only request. Report each platform's version ID, build ID/number,
submission ID/state, item state, release setting, and any remaining blocker. State explicitly
that no `submitted: true` request was sent.

### 8. Submit only the authorized platform and candidate

Immediately before an authorized submission, re-fetch the draft and its items and verify the
platform/version/build and release settings still match the authorization. PATCH that submission
with `submitted: true` once, then GET its resulting state. On a timeout or ambiguous error,
reconcile the live state before retrying. Do not assume a transport error means nothing happened.

Report each platform's resulting state independently. Stop after submission; a manual production
release uses `appStoreVersionReleaseRequests` and requires separate explicit release authorization
plus the `ship-release` skill's gates. This skill must not release a held version as a
side effect of submitting it.

## Completion evidence

For each requested platform report the exact candidate, saved locales, screenshot and fixture
processing, compliance status, release setting, and review state. Store only sanitized evidence
in the release manifest: record IDs, build mapping, states, and timestamps. Exclude credentials,
JWTs, signed upload URLs, private source paths, reviewer contacts, and complete API response dumps.
Do not mark a blocked or partially staged platform complete because the other platform succeeded.
