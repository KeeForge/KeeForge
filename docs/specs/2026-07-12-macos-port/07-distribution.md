# Slice 07: Distribution — Mac App Store + Developer ID

> Parent: [`epic.md`](./epic.md) · Depends on: 02 minimum to ship anything; 01–06 for the full v1 release

## Goal

KeeForgeMac ships through both channels: Mac App Store (universal purchase with iOS, TestFlight, tip jar) and a notarized, sandboxed Developer ID build with Sparkle updates.

## Scope

**In:**
- MAS: Xcode Cloud workflow for the `KeeForgeMac` scheme, TestFlight for Mac, universal-purchase configuration, tip-jar verification, Mac App Store listing assets.
- Direct: Developer ID signing, notarization, Sparkle 2 integration (sandboxed, SPM), appcast hosting, channel-specific tip-jar handling.
- Release-process updates: `release` skill docs, `ci_scripts` docs, KDBX compatibility gate unchanged but run for the mac scheme too.

**Out:** any feature work; marketing site changes beyond the App Store listing; automated UI screenshots (manual is acceptable for mac v1 — a mac variant of `ci_scripts/make_appstore_screenshots.py` is optional).

## Affected areas

- Modified: `project.yml` — a build-config seam distinguishing the MAS and Developer ID builds (e.g., an xcconfig flag consumed at runtime); Sparkle SPM dependency for the Developer ID configuration only if achievable cleanly, otherwise compiled in and inert in MAS (App Review requires Sparkle not to be user-reachable in the MAS build — verify current guidance).
- New: Sparkle plumbing in `KeeForgeMac/` (updater wiring, `SUPublicEDKey` + `SUFeedURL` in the Info.plist for the direct build).
- Modified: tip jar surface — `TipJarView`/`StoreKitManager` hidden in the Developer ID build; replace with a GitHub Sponsors link (already configured for the repo).
- Modified: `.claude/skills/release/` docs and `ci_scripts/README.md` — the release flow gains the mac scheme, notarization (`notarytool`), and appcast-update steps.
- External: App Store Connect (mac platform on the existing `com.keevault.app` app record → universal purchase; TestFlight group), Apple Developer portal (Developer ID certificate), appcast hosting (HTTPS).

Hardening requirements (non-negotiable, from the security review):
- Hardened Runtime already on from slice 01; this slice proves it end-to-end: the notarized artifact shows **no `get-task-allow`, no `com.apple.security.cs.*` exceptions** — Sparkle 2 via SPM needs none (Xcode signs its XPC services with the team ID; library validation permits same-team). Never add `disable-library-validation` or `allow-dyld-environment-variables`.
- Both channels stay sandboxed — one behavior, one QA matrix.
- Sparkle chain: EdDSA private key generated and stored outside the repo and CI logs (e.g., local keychain); HTTPS-only appcast; `SUPublicEDKey` pinned in Info.plist.

## KeeForge bits

- **Targets:** Sparkle wiring → KeeForgeMac only (config-gated). No shared-source changes.
- **project.yml:** config seam + optional Sparkle package as above. Run `xcodegen generate`.
- **Accessibility identifiers:** N/A — only the tip-jar-vs-sponsors swap touches UI; preserve `tipjar.*` identifiers in the MAS build.

## Testing

- **Unit:** existing `StoreKitManager`-adjacent tests stay green; new: channel-flag test — Developer ID configuration hides tip jar and enables the updater surface, MAS configuration the reverse.
  Run slice: `-only-testing:KeeForgeMacTests` (full mac unit suite as the release gate).
- **Integration / UI:** the slice-02 mac smoke suite runs against the release configuration.
- **Manual (release checklist — becomes part of the release skill docs):**
  - MAS: Xcode Cloud archive succeeds; TestFlight install on a clean Mac; tip-jar purchase in sandbox; universal purchase recognized (install with an account that owns the iOS app).
  - Direct: `notarytool` accepts; `spctl --assess` (Gatekeeper) passes on the exported artifact; `codesign -d --entitlements -` shows hardened runtime, app-sandbox, and no cs-exceptions; first-launch on a clean Mac (quarantine bit) opens without warnings.
  - Sparkle: publish a test appcast entry → in-app update downloads, verifies signature, installs, relaunches (inside the sandbox).
  - KDBX gate: `ci_scripts/run_kdbx_compatibility_gate.sh` passes; artifacts from the mac build validate with keepassxc-cli identically to iOS.
  - Security regression sweep (from the epic): reveal/copy prompts for login password on a non-Touch-ID Mac; vault locks on screen-lock, sleep, screensaver; clipboard clears on lock and after timeout.
- **Edge cases that apply:** update while a database is unlocked (Sparkle relaunch must go through the lock path), MAS receipt absent in Developer ID build (no StoreKit calls), both builds installed side by side (same bundle ID — document that this is unsupported; last-opened wins file associations).

## Exit criteria

- [ ] Full mac unit suite + smoke suite green in the release configuration; iOS release flow untouched and green.
- [ ] Both channels' manual checklists executed and recorded.
- [ ] No force unwraps; no new entitlements beyond the planned set.
- [ ] `xcodegen generate` run; `release` skill and `ci_scripts/README.md` updated.
- [ ] CHANGELOG entry under `## Unreleased`.

## CHANGELOG entry

`- KeeForge for Mac: available on the Mac App Store (universal purchase with iOS) and as a notarized direct download with in-app updates.`
