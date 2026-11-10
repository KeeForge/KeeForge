# iPhone Duo support

Date: 2026-11-08.
Baseline reviewed: `236f7bef`.
Status: implemented on 2026-11-08 (slices 1–4). The current rules live in
`KeeForge/App/AGENTS.md` ("Layout changes"); this document is not maintained.
See "What implementation found" at the end for where it differs.

## Summary

iPhone Duo is Apple's first foldable. It shipped on 2026-10-23 with iOS 27.
It has a 5.4-inch outer display and a 7.6-inch inner display, and the app
resizes live when the user opens or closes it.

KeeForge already runs on it without changes. The work is to make the switch
between the two displays lossless and to verify the security behavior around
it. Most of the risk is already in the code today: iPad Split View and Stage
Manager resizes trigger the same paths, but users rarely hit them. On the Duo
they happen every time the phone opens or closes.

The deployment floor stays at iOS 18. Adopt no iOS 27.1-only API in this
work.

## What Apple's guidance says

Sources:

- Apple's [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)
  overview.
- The HIG page [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo).
- Tech Talks 111461–111466.

Where the talks and the overview differ, the overview wins. The two pages
are rendered by JavaScript, so read them in a browser.

The HIG states the goal this spec implements: "Keep functionality and the
state of elements the same between displays."

| Topic | Platform behavior |
| --- | --- |
| Size classes | Outer display: compact width, regular height in portrait; compact both in landscape. Inner display: regular width and regular height, like iPad. The idiom stays `.phone`. |
| Resizing | "Your app will still resize" on open/close. `UIRequiresFullScreen` is still honored, but the app still resizes. |
| Orientation | The inner display does not honor `UISupportedInterfaceOrientations`. Use size classes. |
| Multitasking | All apps take part. Split View is 50/50. Multiple windows need an app to opt in to multiple scenes. |
| Navigation | `NavigationSplitView` and `TabView` adapt to every pose. |
| Layout signals | Don't use `userInterfaceIdiom` or interface orientation for layout. Base layout on the scene's or containing view's bounds, not the screen's. |
| Sheets | On the outer display, sheet bars are vertical by default. `toolbarVerticalBehavior(_:)` (SwiftUI) or `preferredVerticalBarBehavior` (UIKit) turns this off. On the inner display, a trailing sheet's toolbar is vertical. Alerts, context menus and sheets move clear of the fold on their own. |
| SDK | Apps built with Xcode 26 or earlier don't extend under the status bar and camera. The talks add that the iOS 27.1 SDK (Xcode 27.1) reaches the screen edge. Device Hub previews the Duo in each pose. Apple says simulators don't replicate hardware features, so verify on a device. |
| `UIScreen.main` | Avoid it. The talks say it "will be deprecated in a future release". Read the screen through the window scene or the trait collection. |
| New iOS 27.1 APIs | Reserved regions (hinge and system UI), arrangements, `onHingeChange` / `UIHingeInteraction`, vertical toolbars, camera scene accessories. |

Neither the overview, the HIG page nor the talks covers these:

- What scene phase the app passes through during open/close.
- Whether there is a per-app setting for continuing on the outer display.
- Display point sizes.
- Credential-provider extension sizing.
- Where Face ID sits.
- Screen-capture or snapshot behavior on the outer display.
- How to open and close the simulator from tests.
- Any App Store screenshot requirement.

Each of these is listed under [Open questions](#open-questions).

## How KeeForge behaves today

- **One shell switch at the root.** `KeeForgeApp.usesRegularLayout`
  (`KeeForge/App/KeeForgeApp.swift:566`) picks one of two shells:
  - Compact: `CompactDatabaseHost`, a single `NavigationStack` on
    `workspace.navigationPath`.
  - Regular: `RegularDatabaseWorkspaceView`, a `NavigationSplitView`.

  Open/close flips this every time.
- **The two shells keep separate state.** On a swap:
  - The regular sidebar's path is local `@State`
    (`RegularDatabaseWorkspaceView.swift:11`), so the compact path does not
    carry over to it.
  - `detailEditor` (`:18`) holds an unsaved New Entry or Edit Group draft,
    and the swap destroys it.
  - `CompactDatabaseHost.hasUnlockedInThisSession`
    (`KeeForgeApp.swift:678`) resets, and an in-progress unlock page is
    dismissed.
  - Opening the phone mid-edit loses the user's place, and possibly their
    draft.
- **Per-view adaptation already uses size class, not idiom.** The
  following follow the Duo correctly with no device checks:
  - `GroupListView` bottom bar and Lock button.
  - `EntryDetailView` Lock button.
  - The iOS 26 selection chrome.
  - The `ViewThatFits` rows.

  The app has no `userInterfaceIdiom` or `GeometryReader` layout code.
- **Plist.** The app supports all four orientations and does not set
  `UIRequiresFullScreen`. It does not declare multiple scenes, so it runs as
  one instance only. `TARGETED_DEVICE_FAMILY` is `1,2`.
- **`UIScreen.main`** appears in one place: `ScreenProtectionService`
  (`KeeForge/Services/Security/ScreenProtectionService.swift:24`) reads
  `isCaptured` from it.
- **Lock.** Locking happens only on `.background`, or on the auto-lock
  deadline checked at `.active` (`DatabaseViewModel.swift:3729`). The privacy
  shield arms a transparent overlay when the scene deactivates and turns
  opaque only on background or capture.
- **AutoFill extension.** Every screen is a full-screen `UIHostingController`
  with a `NavigationStack` and no size logic. It has the same 520pt content
  cap as the app's unlock screen.
- **Tests.**
  - `ViewRenderTests` renders 375pt and 440pt columns only.
  - `requireRegularWidthLayout()` gates on a window at least 700pt wide.
  - `EntryEditUITests.swift:1351` decides the iOS 26 selection title by
    idiom. On an unfolded Duo (phone idiom, regular width) it expects the
    wrong layout.
  - Nothing tests a live resize.

## Goals

1. Opening or closing the phone preserves where the user was:
   - the open database,
   - the group path,
   - the selected entry,
   - any unsaved editor draft,
   - the database being unlocked.
2. Opening or closing never locks the vault, shows the opaque shield, or
   drops a save, unless the system really backgrounds the app.
3. Both displays get the layout they report: compact (iPhone) on the outer
   display, regular (iPad workspace) on the inner one. This also covers 50/50
   Split View.
4. AutoFill works on both displays and survives a fold mid-flow.
5. CI covers the path mapping and both widths, and the RC process runs on the
   Duo simulator.

## Non-goals

- **Multiple windows.** It would need multi-scene support, a lock policy per
  scene, and a privacy shield per scene. That is a separate design with a
  threat-model change.
- **iOS 27.1-only APIs.** This covers hinge, reserved regions, arrangements,
  vertical toolbars and camera accessories. The app's custom UI does not
  cross the fold, and the system containers already handle partial fold.
  Revisit when the deployment floor moves.
- **Duo-specific layouts.** The inner display uses the iPad workspace as is.
- **Mac.** It is not affected.

## Design

### 1. One workspace navigation model for both shells

Make `DatabaseWorkspaceState` the single owner of navigation for both shells:

- Move the regular sidebar's `navigationPath` out of
  `RegularDatabaseWorkspaceView` `@State` and into the workspace state, next
  to `selectedEntryID`.
- Add pure mapping functions on `DatabaseWorkspaceState`. They run when
  `usesRegularLayout` changes:
  - **Compact → regular:**
    - A trailing `.entry(id)` route becomes `selectedEntryID`.
    - The group routes before it become the sidebar path.
    - An editor route becomes the hosted detail editor (see section 2).
  - **Regular → compact:**
    - The sidebar path becomes the stack.
    - `selectedEntryID` is appended as an entry route.
    - An open detail editor is appended after it.
- `RegularDatabaseWorkspaceView` clears `selectedEntryID` in
  `.onChange(of: navigationPath)`. That must not fire for the mapping itself.
  Apply the mapping as one state transition, or have the clear ignore it.

This also fixes iPad Split View and Stage Manager resizes. Record the
invariant in `KeeForge/App/AGENTS.md`: a size-class change keeps workspace
navigation.

### 2. Editor drafts survive a shell swap

An editor that is open during a swap must come back with its unsaved
contents.

- Lift the identity of the open editor out of view `@State`:
  - `detailEditor` on regular.
  - The pushed editor route on compact.

  Move it into the workspace state.
- Keep the draft in the editor's existing draft model (`DatabaseDraft` /
  `EntryEdit`), owned by the workspace instead of by the view. This keeps
  decrypted field values in the same in-memory, session-key-protected form
  they use today. They are not persisted.
- Lock discards the draft exactly as it does today.

Sheets stay as they are: the Password Generator, icon pickers and field-order
sheet survive a resize because the presenting view survives. Verify each
one, and lift any that is dismissed.

On the outer display, sheet toolbars become vertical by default. Check that
each sheet's Cancel and Done placements still read correctly that way. The
opt-out (`toolbarVerticalBehavior(_:)`) is a new API that the iOS 18 floor
lacks. Use it only behind `#available`, and only for a sheet that breaks, because the system default is
the platform convention.

### 3. Unlock across a swap

The database being unlocked is kept. Compact presents its unlock page and
regular renders unlock inline for the same reference. Typed master-password
text is not carried over: it lives only in the unlock view, and copying it
into longer-lived state widens where the secret sits. A Face ID prompt that
is in progress when the phone opens or closes is cancelled by the system.
Make sure `BiometricAutoUnlockModifier` does not treat that as a user cancel
that blocks a retry.

Move `hasUnlockedInThisSession` to the workspace state so the swap does not
re-trigger first-unlock behavior.

### 4. Lifecycle and security

- **Lock policy stays tied to scene phase.** Add no hinge or display
  special-casing.
  - If iOS backgrounds the app when it closes (for example, a "continue on
    outer display" setting is off), locking is correct and expected.
  - If it only resizes, nothing locks.
  - The device check below decides which case applies. Document the result
    in the user-facing auto-lock help, not as a code branch.
- **Privacy shield.** A short `.inactive` during the transition only arms
  the transparent overlay today. Verify it never turns opaque or stays up
  after the transition.
- **Remove `UIScreen.main`.** Replace `UIScreen.main.isCaptured` with the
  scene's capture state, for example the `sceneCaptureState` trait (iOS 17)
  on the active window scene. Capture then follows the display the app is
  on. Keep `UIScreen.capturedDidChangeNotification` only if the trait route
  cannot observe changes.
- **Threat model.** No change unless a device check shows a new path, such
  as the outer display showing a stale snapshot of unlocked content after
  close. If one turns up, update `docs/threat-model.md` in the same change.

### 5. AutoFill extension

There is no code change unless testing finds a problem. Verify:

- Search, entry creation and passkey creation on both displays.
- Opening or closing during search and during the `UIAlertController`
  unlock. The extension must not lose the request or complete it twice.
- Content width on the inner display. The 520pt cap keeps fields readable.

### 6. Fix layout assumptions in tests

- `EntryEditUITests.swift:1351`: base the expectation on window width (the
  same signal as `requireRegularWidthLayout()`), not idiom. Apple's guidance
  rules out idiom for layout decisions.
- Confirm that the inner display's window width clears the 700pt
  `requireRegularWidthLayout()` threshold. If it does not, change the gate so
  regular-width classes run on the Duo instead of being skipped.

## Testing

| Layer | Coverage |
| --- | --- |
| Unit (`KeeForgeTests`) | The compact ↔ regular mapping in `DatabaseWorkspaceState`: root, nested group, entry, editor, search, selection mode, round-trip identity. Draft ownership survives a remap and is cleared on lock. |
| Render | Add `ViewRenderTests` columns for the outer-display width and the inner display's regular width. Take the point sizes from the iPhone Duo simulator, not from published specs. |
| UI (simulator) | Run the existing `RegularWidthWorkspaceUITests` and `DatabaseCreationRegularWidthUITests` on the iPhone Duo simulator (unfolded). Run the compact classes folded. Add a resize UI test only if XCUITest can trigger open/close in the simulator (open question). Otherwise cover the transition with the unit mapping tests and the manual checklist. |
| CI | Add an iPhone Duo lane to `.github/workflows/ios-rc-tests.yml` beside the `iPad (A16)` lane, running the regular-width classes. Add a matching Studio plan in the private `studio-tests.local.conf`. |
| Device | Manual checklist on a physical Duo: open/close during each state in Goal 1, with lock-on-background on and off, during screen recording, and in AutoFill from Safari. The designated test phone is not a Duo, so simulator results are not device coverage until this is run. |

## Delivery slices

Each slice ships on its own and leaves the app working.

1. **Baseline.**
   - Build with Xcode 27.1 and smoke-test on the Duo simulator.
   - Replace `UIScreen.main` (section 4).
   - Fix the idiom test (section 6).
   - Add the render widths.
2. **Navigation continuity.** The single navigation model and mapping
   (section 1), with unit tests. This also fixes iPad resizes.
3. **Draft and unlock continuity.** Sections 2 and 3, with unit tests.
4. **CI and verification.**
   - The Duo CI and Studio lanes.
   - The AutoFill and lifecycle checks (sections 4 and 5).
   - The device checklist.
   - A `CHANGELOG.md` entry.
   - The `AGENTS.md` updates in `KeeForge/App/` and `KeeForgeUITests/`.

## Open questions

1. **Scene phase on open/close.** Does iOS 27 deliver `.inactive` only, or
   `.background`, and is there a user setting that changes it? This decides
   whether lock-on-background fires on close. It needs a simulator and
   device check before slice 4 closes.
2. **Inner display window width.** It decides the test gate in section 6.
3. **Simulating open/close in UI tests.** Can XCUITest or `simctl` open and
   close the Duo simulator? Device Hub can change the pose interactively.
   Apple's "Interacting with devices using the command line" page has not
   been checked.
4. **App Store screenshots.** Does App Store Connect require or accept a
   Duo screenshot class? Check Apple's "Screenshot specifications" page. If so, extend `ci_scripts/make_appstore_screenshots.py`
   and the `publish-app-store-version` steps.
5. **Unlock text across a swap.** Is dropping typed master-password text on
   a swap acceptable UX? The alternative holds it in workspace state until
   unlock or lock.

## What implementation found

- **Display sizes.** The Xcode 27.2 iPhone Duo simulator has an outer display
  of 466×678pt and an inner one of 669×951pt (both at 3×). The UI tests' 700pt
  regular-width gate would have skipped on the open Duo, so it is now 600pt
  (`usesRegularWidthLayout`).
- **Simulating open/close.** Neither `simctl` nor XCTest can open or close the
  simulator, and it boots closed. `LayoutSwitchUITests` switches layouts
  through an in-app control (`-ui-testing-layout-switch`) instead, and runs
  on the iPad and Duo CI lanes.
- **Render widths.** No new render column: the outer display is 26pt wider
  than the existing 440pt column, and the inner display uses the iPad
  workspace, which the render tests do not compose.
- **Unlock.** Nothing moved. The database being unlocked already lives on the
  root, and the automatic Face ID attempt is claimed once per lock cycle on
  `DatabaseViewModel`, so a switch neither loses the unlock nor prompts again.
  Typed password and key-file choice reset, as section 3 intended.
- **Editors.** Duplicate from search results and the tag browser now opens
  the workspace's editor too. On iPhone it is pushed rather than shown as a
  sheet, and on iPad it is hosted in the detail column, like every other
  editor.
- **Vertical bars.** On the outer display iOS 27 puts navigation bars
  vertically down the right edge, for every screen, not only sheets. The app
  works there, but the shared UI-test helpers for Back and search look for a
  horizontal top bar, so ten tests in five classes failed on the closed Duo
  simulator. The helpers now also look in the right-edge bar, and the Duo CI
  lane runs the layout, AutoFill picker, creation, entry and tag classes.
- **Device Hub poses.** Driving Device Hub by hand on the iOS 27.1 simulator:
  an entry editor with an unsaved title stayed open, with its text, through
  Open → Closed → Open → Partially Open. Partially Open keeps the regular
  layout. The database stayed unlocked throughout.
- **Answered by research (no device).**
  - *Scene phase (question 1).* Apple's developer-forum answers describe
    open and close as a window resize on the same scene, not a trip to the
    background, and no setting that backgrounds the app on close turned up. Lock-on-background therefore does not fire on a switch; the
    auto-lock timer and screen lock still apply. A brief `.inactive` during
    the animation is undocumented. The app's covers already handle
    `.inactive` without locking, so either answer is safe.
  - *Biometrics.* The iPhone Duo has Touch ID in the side button and no Face
    ID. Unlock buttons and error copy already follow the device's biometry
    type; the iOS Settings toggle and its footer said "Face ID" on every
    device and now say "Touch ID" on Touch ID devices.
  - *App Store screenshots (question 4).* App Store Connect has an iPhone Duo
    screenshot class. It is optional until April 2027 for apps built with
    the iOS 27.1 SDK; until then the iPhone screenshots are used.
- **Still open.** Whether a Touch ID prompt or an AutoFill sheet survives an
  open or close mid-prompt has no public answer and needs a device; both
  fail safe (the prompt cancels and the unlock page shows). Question 5 is an
  owner decision.
