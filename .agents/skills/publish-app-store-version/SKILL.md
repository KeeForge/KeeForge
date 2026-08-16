---
name: publish-app-store-version
description: Prepare and publish an already-built KeeForge version through the App Store Connect website. Use when the user asks to create or finish an App Store version, publish an uploaded build, prepare an App Review submission, stage everything before the final submit, or operate App Store Connect after the release/tag/CI workflow is complete. Covers build processing, export compliance, localized release notes, reviewer information and test fixture, release settings, review staging, and final submission. Do not use for version bumps, release candidates, tags, compatibility gates, or archive creation; use the release skill for those tasks.
---

# Publish KeeForge App Store Version

## Scope

Drive the post-build App Store Connect workflow for KeeForge. Use browser control because this work depends on the signed-in App Store Connect UI.

Do not repeat the repository release workflow. Assume the requested version was already cut unless the user says otherwise. If no processed build exists, report that clearly or wait for the user to upload one.

Treat **Submit for Review** as the final consequential action. Prepare everything first and stop immediately before it unless the user explicitly asks to submit and confirms at action time.

## The build is already chosen

The `release` skill soaks a specific build on the public TestFlight channel and hands this skill an
exact `{marketing version, build number}` pair. That pair is the release. This skill **selects**
that already-uploaded build; it never triggers, requests, or waits for a new one.

If the user supplies a version without a build number, ask for it — do not infer it from "the
latest build". The latest TestFlight build is not necessarily the soaked one, and shipping a
different binary than the one that was soaked defeats the entire release process.

If the requested build is absent from TestFlight, stop and report it. Do not start a build.

## KeeForge release inputs

- Read `CHANGELOG.md` and use only the section for the requested version. Do not include `Unreleased` entries.
- Reviewer fixture: `/Users/tan/Documents/test.kdbx.zip`
- Reviewer fixture password: `testpassword123`
- Preserve the existing reviewer note unless it is incorrect. It should tell the reviewer that the compressed test database is attached and give the password.
- App Store localizations: verify against the version page in App Store Connect (last known: English (U.S.), French, German, Russian, Spanish (Spain); consider adding Simplified/Traditional Chinese since the app ships them in-app as of 1.14.0).

## Workflow

### 1. Inspect current state

1. Open the KeeForge app in App Store Connect.
2. Check whether the requested iOS version already exists and note its state.
3. Check TestFlight build uploads for the exact marketing version and build number handed over by the `release` skill.
4. Treat `Complete` as processed. Do not attach a build that is still processing or failed.
5. Confirm the build was distributed to external testers — that is the one that was soaked. A build that only ever reached internal testers has not been through the process.
6. If the build is missing, report it and stop. Builds are produced by the Xcode Cloud **Tests (RC)** workflow on an `rc/*` tag; no workflow triggers on `v*`. Never start a build from here.

### 2. Create the App Store version when needed

Create the exact version through **Add iOS App**. Confirm immediately before creating the version record because it changes App Store Connect state.

Do not create a duplicate version if it already exists.

### 3. Verify export compliance

`KeeForge/Info.plist` declares `ITSAppUsesNonExemptEncryption` as `false`, so App Store Connect
normally resolves compliance from the build metadata without prompting. Verify it shows as
resolved rather than assuming it.

If App Store Connect still asks, KeeForge implements standard encryption outside or in addition to Apple's operating-system encryption. Inspect the previous accepted build's **Build Metadata** first so the declaration stays consistent with prior submissions. The recorded declaration path is:

1. **Standard encryption algorithms instead of, or in addition to, using or accessing the encryption within Apple's operating system**
2. **No** for availability in France

These are legal declarations. Present the exact choices and obtain explicit user confirmation at action time before saving them. If the user's answer differs, follow the user rather than this recorded precedent.

### 4. Attach the build

1. Open **Add Build**.
2. Select the exact soaked build — match **both** the marketing version and the build number from the handoff. When several builds exist for the version, the highest build number is not automatically the right one.
3. Verify the build number and marketing version before choosing **Done**.
4. After attachment, verify the build row on the version page shows the expected build number.
5. If the only builds offered do not include the handoff build number, stop and report the mismatch instead of substituting a different build.

### 5. Write localized release notes

Draft concise English release notes from the versioned changelog section. Prefer user-facing outcomes over implementation detail. Mention minimum-OS changes explicitly.

Show the English draft to the user before saving it as public metadata. After approval:

1. Save English (U.S.).
2. Translate the same meaning faithfully into every other localization listed on the version page.
3. Save each localization separately.
4. Keep product terms such as KeeForge, KeePass, KDBX, AutoFill, WebDAV, TOTP, passkey, and iOS recognizable.

If **Add for Review** reports missing localized `What's New in This Version` fields, use the listed locales as the source of truth, fill every missing field, save, and retry.

### 6. Verify reviewer information and attachment

Before adding the version for review, verify all of the following:

- Contact information is populated.
- Sign-in is not required unless current app behavior changes.
- Reviewer notes mention the attached compressed database and password `testpassword123`.
- The **Attachment** section shows `test.kdbx.zip`.

If the attachment is absent:

1. Confirm `/Users/tan/Documents/test.kdbx.zip` exists.
2. Read the browser file-upload guidance.
3. Upload that exact file through **Choose File (Optional)** using the file-chooser flow.
4. Verify the filename appears after upload.

Do not upload a duplicate when the attachment is already present. If the file is missing, stop and ask the user for the correct path.

### 7. Verify release behavior

Preserve the prior version's settings unless the user requests a change. For KeeForge, verify:

- **Automatically release this version** is selected.
- **Release update to all users immediately** is selected.
- **Keep existing rating** remains selected.

Report any difference before changing it.

### 8. Stage the review submission

1. Save the version metadata.
2. Choose **Add for Review**.
3. Resolve every concrete validation error App Store Connect lists.
4. Wait for the version state to become **Ready for Review**.
5. Open the draft submission and verify it contains the exact version and build.
6. Verify **Item Ready to Submit** and the presence of **Submit for Review**.

Stop here when the user asked to complete everything before final submission. Leave the draft open and report that the final button is untouched.

### 9. Submit only on explicit confirmation

If the user explicitly asks for final submission, request action-time confirmation that clicking **Submit for Review** will send the version and its metadata to Apple for review. After confirmation:

1. Click **Submit for Review** once.
2. Verify the resulting submission state from the page.
3. Report the observed state and the configured automatic-release behavior.

## Final checklist

- Exact version record exists.
- The attached build is the exact soaked build number from the handoff, not merely the newest.
- Exact build is processed and attached.
- Export compliance is complete.
- France availability is consistent with the compliance declaration.
- Release notes are saved for every localization listed on the version page.
- Reviewer note includes the fixture password.
- `test.kdbx.zip` is visibly attached.
- Automatic release, immediate rollout, and rating retention are verified.
- Draft submission shows the exact version and build as ready.
- Final submit is untouched unless separately confirmed.
