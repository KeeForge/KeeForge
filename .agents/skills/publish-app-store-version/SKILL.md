---
name: publish-app-store-version
description: Prepare and publish an already-built KeeForge version through the App Store Connect website. Use when the user asks to create or finish an App Store version, publish an uploaded build, prepare an App Review submission, stage everything before the final submit, or operate App Store Connect after the release/tag/CI workflow is complete. Covers build processing, export compliance, localized release notes, reviewer information and test fixture, release settings, review staging, and final submission. Do not use for version bumps, release candidates, tags, compatibility gates, or archive creation; use the release skill for those tasks.
---

# Publish KeeForge App Store Version

## Scope

Drive the post-build App Store Connect workflow for KeeForge. Use browser control because this work depends on the signed-in App Store Connect UI.

Do not repeat the repository release workflow. Assume the requested version was already cut unless the user says otherwise. If no processed build exists, report that clearly or wait for the user to upload one.

Treat **Submit for Review** as the final consequential action. Prepare everything first and stop immediately before it unless the user explicitly asks to submit and confirms at action time.

## KeeForge release inputs

- Read `CHANGELOG.md` and use only the section for the requested version. Do not include `Unreleased` entries.
- Reviewer fixture: `/Users/tan/Documents/test.kdbx.zip`
- Reviewer fixture password: `testpassword123`
- Preserve the existing reviewer note unless it is incorrect. It should tell the reviewer that the compressed test database is attached and give the password.
- Existing App Store localizations: English (U.S.), French, German, Russian, and Spanish (Spain).

## Workflow

### 1. Inspect current state

1. Open the KeeForge app in App Store Connect.
2. Check whether the requested iOS version already exists and note its state.
3. Check TestFlight build uploads for the exact marketing version and build number.
4. Treat `Complete` as processed. Do not attach a build that is still processing or failed.
5. If the build is missing, check whether the Xcode Cloud **Release** workflow uses **Distribution Preparation: App Store Connect**. Never start another build when the user says they will archive and upload manually.

### 2. Create the App Store version when needed

Create the exact version through **Add iOS App**. Confirm immediately before creating the version record because it changes App Store Connect state.

Do not create a duplicate version if it already exists.

### 3. Resolve export compliance

Inspect the previous accepted build's **Build Metadata** before answering so the declaration stays consistent with prior submissions.

KeeForge implements standard encryption outside or in addition to Apple's operating-system encryption. The current declaration path is:

1. **Standard encryption algorithms instead of, or in addition to, using or accessing the encryption within Apple's operating system**
2. **No** for availability in France

These are legal declarations. Present the exact choices and obtain explicit user confirmation at action time before saving them. If the user's answer differs, follow the user rather than this recorded precedent.

### 4. Attach the build

1. Open **Add Build**.
2. Select the exact processed build for the requested version.
3. Verify the build number and marketing version before choosing **Done**.
4. After attachment, verify the build row on the version page.

### 5. Write localized release notes

Draft concise English release notes from the versioned changelog section. Prefer user-facing outcomes over implementation detail. Mention minimum-OS changes explicitly.

Show the English draft to the user before saving it as public metadata. After approval:

1. Save English (U.S.).
2. Translate the same meaning faithfully into French, German, Russian, and Spanish (Spain).
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
- Exact build is processed and attached.
- Export compliance is complete.
- France availability is consistent with the compliance declaration.
- English, French, German, Russian, and Spanish release notes are saved.
- Reviewer note includes the fixture password.
- `test.kdbx.zip` is visibly attached.
- Automatic release, immediate rollout, and rating retention are verified.
- Draft submission shows the exact version and build as ready.
- Final submit is untouched unless separately confirmed.
