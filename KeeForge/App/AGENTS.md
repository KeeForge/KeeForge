# App

**Scope:** app startup, scene phase, the adaptive root shell that connects the database list to one active session, and the macOS menu bar. Compiled into `KeeForge` and `KeeForgeMac`, not the AutoFill targets.

## Ownership

Keep scene and platform adapters here and lifecycle decisions in the owning view model or service. Do not hide an app-wide state transition inside a view.

- `KeeForgeApp` owns the optional active `DatabaseViewModel`, the shared `DatabaseListViewModel` and `AppRoutingCoordinator`, and the compact vs regular root choice. macOS always uses the regular layout.
- Launch order, incoming URLs, pending TOTP enrollment, and Open/Close Database transitions are decided by `../ViewModels/AppRoutingCoordinator.swift` (see `../ViewModels/AGENTS.md`). `AppRootView` only adapts the result to SwiftUI presentation.
- Auto-unlock is attempted in one place per platform: `.biometricAutoUnlock(_:)` on the iOS scene shells, and `MacBiometricAutoUnlockObserver` hosted once per active session by `AppRootView` on macOS. Eligibility is `DatabaseViewModel.isEligibleForBiometricAutoUnlock`.
- `RegularDatabaseWorkspaceView` owns the regular-width unlocked workspace: a two-column split on iPad, the three-column `macSplitView` on macOS. It hosts every sheet and confirmation its rows raise.
- `KeeForgeCommands` (KeeForgeMac only) owns the menu bar. Items reach the session through `FocusedValues` and act through `DatabaseViewModel`; the four that need a presentation only raise a `workspace` request counter (`../ViewModels/AGENTS.md`).
- `MacLockMonitor` is the sole lock driver on macOS; `MacWindowCloseGuard` settles unsaved work before a window close commits (`../Services/AppSupport/`).

## Invariants

### Scene phase and locking

- Backgrounding always shows the capture shield. On iOS it locks only when `SettingsService.lockOnBackground` is on; otherwise the `autoLockTimeout` check runs on the next activation.
- The scene-phase `.background` lock path is iOS-only. macOS backgrounds a scene on window minimize and app hide, which must not lock; `MacLockMonitor` applies the Mac policy instead.
- iOS observes touches across the main window (including sheets) and text-field/text-view edits through `IOSUserActivityObserver`. Only foreground activity resets the inactivity timer; its passive recognizer must never delay, cancel, or prevent normal controls and scrolling.
- On the compact shell only a manual lock calls `VaultCloseTransition.coverCurrentFrame()`, immediately before the closing state change. An automatic lock can coincide with backgrounding, and a snapshot added then is what iOS would capture for the app switcher.
- Pending AutoFill uploads drain on foreground activation (scene phase, and `MacLockMonitor.onDidBecomeActive` on macOS) and on the extension's Darwin notification. Both go through `DatabaseListViewModel.drainPendingUploadsOnAppActive()`.
- A change to background/foreground behaviour needs checking in both shells together with AutoFill cache refresh and pending-upload drain timing.

### Launch and presentation

- Open cloud databases keep Sync Now below the iPad sidebar title and in the Mac database toolbar. The iPhone header shows only a status badge beside the title (a spinner while syncing, a warning whose popover offers Sync Now), and pulling a cloud list down syncs on every iOS layout. Skipped-check, last-sync, pending-upload, and result text lives in its status popover; choosing a future sync policy never claims the current open skipped a check. Sync enablement comes from `DatabaseViewModel.canSyncCloudNow`.
- Unlock, unlocking, and unlocked are one selected-database flow. Compact presents unlock as a sheet over the list and swaps to the session once unlocked; regular renders all three states inline in the detail column.
- Quick Launch waits until the What's New sheet (and the Mac transition notice) is dismissed, so two launch presentations never compete.
- SwiftUI drops a presentation raised while another sheet is dismissing. That is why deferred presentations wait 450 ms and why the conflicted-upload notice is a banner, not an alert: it is due at unlock, while the compact unlock sheet is dismissing.
- The iOS Settings sheet is attached above the root so it survives the lock/unlock root swap. It exists for the iPad app running on a Mac, where the sidebar gear is hidden and the system Settings item opens a compatibility window.
- Never hand a view a closure over a captured `$activeDatabaseViewModel`. A `Binding` read inside a view update returns the value it was created with, so the closure reads `nil` from a view body or `updateNSView`. Closures that run only from notifications, timers, event monitors, or control actions may capture it.
- The main window's minimum height (620) must stay clear of `MacSheetMetrics.maxHeight` (560, `../Extensions/PlatformCompat.swift`): a sheet is anchored under the toolbar. Raise them together.

### Auto-unlock

- On iOS, one attempt per `lockCycleID`, and only while `scenePhase == .active`: LocalAuthentication fails with `LAError.notInteractive` for a caller that is not foreground-active, which would burn the cycle's attempt on an error screen.
- An attempt that returns `.promptUnavailable` showed no UI and gives its lock cycle back.
- On Mac, attempt only when the session mounts in a foreground key window or that window/app returns to the foreground, including a screen unlock or session switch back while KeeForge stays active (`MacBiometricAutoUnlockController.startObserving`). Never trigger from a lock-cycle change. Defer past activation observers and recheck eligibility, window visibility, attached sheets, and the captured lock cycle before prompting. Cancellation or fallback consumes the cycle; the password form stays available. Pending work is invalidated on unmount.
- The Mac observer lives above the locked/unlocked view switch, keyed by session. Mounting it counts as opening, so placing it inside a view that a lock replaces would prompt on every automatic lock while the window is frontmost.
- `BiometricAutoUnlockPolicy` disables auto-unlock for the iOS build running on Mac or Vision Pro, because `active` does not prove the compatibility window is frontmost. Those keep the explicit biometric action in `UnlockView`.

### macOS workspace lists

- The group sidebar width lives in scene storage, outside the unlocked workspace's lifetime. Measure the visible column and restore its preferred width on unlock; never retain database contents to preserve layout. Only a width measured in a split view of unchanged width is a preference: a narrower window compresses the column without replacing it (`MacSidebarWidthSampler`). Keep `navigationSplitViewColumnWidth` the column's outermost modifier: wrapped by `onGeometryChange`, the split view ignored it on macOS 27.0.1 and laid the sidebar out at 144 pt.
- All three browsing columns are native `List(selection:)` so arrow keys, type-select, and the focus ring come from AppKit. Rows are plain content, not buttons: a `Button` swallows the click the list needs.
- Do not rely on the list still selecting under a row's tap gesture. On macOS 27.0 it does (`onTapGesture`, `simultaneousGesture`, and double-tap variants all still move the selection); the earlier releases where the gesture was recorded as consuming the click are unverified. Sidebar rows carry no tap gesture; the disclosure triangle is the only way to fold a group.
- The entries column wants double-click-to-open, so its row (`../Views/Entry/MacEntriesList.swift`) handles the single click itself: it sets `selectedEntryID` and focuses the list, so neither selection nor arrow keys depend on what the list does with that click. The sidebar's selection binding takes focus on every write for a related reason: on macOS 27.0 a click on a gesture-free row, or an accessibility selection, moves the selection without making the list first responder.
- Because rows are not buttons, Mac UI tests match them with `descendants(matching: .any)`; the rule is stated in `../Views/AGENTS.md` and `../../KeeForgeMacUITests/AGENTS.md`.
- The macOS sidebar cannot host pushed `NavigationStack` levels (they render zero-height), so navigation there is selection on `DatabaseViewModel.workspace`, never a pushed stack. `GroupListView` never renders on macOS.
- The sidebar and entries column are keyed with `.id(viewModel.contentRevision)` because the three-column split view caches them and keeps stale rows after draft edits. View-local state inside those subtrees is lost on every edit; expansion and selection live outside them.
- `MacGroupNode` resolves custom group images from the current metadata for the shared `GroupIconView`; the recycle bin always uses standard icon 43 with no custom image.
- Sheets, the Move picker, and the delete confirmation raised by a row are hosted on the split view, not the row. Rows come and go with the tree, and a row-scoped host is torn down mid-presentation.
- The delete confirmation is a `confirmationDialog`, not a second `.alert(item:)`: two sibling `.alert(item:)` on one view chain collide and SwiftUI silently drops one. Lists rendered inline in the content column raise their deletion to this host for the same reason.
- Database-scoped toolbar items use `.navigation` placement. `.primaryAction` would put them beside entry detail's Edit button, where they read as actions on the selected entry.

### iPad workspace

- Successful New Entry completion selects the saved entry through `revealEntry` in both regular shells, including a changed destination group. Cancel, edit, and Save and Lock keep their existing selection behavior.
- Editors raised from the sidebar (New Entry, Edit Group) are hosted in the detail column, not pushed into the narrow sidebar. A hosted editor keeps its unsaved work: later requests are ignored while one is up.
- iPad mini in portrait starts with the sidebar collapsed behind the system "Show Sidebar" button. That is the platform's default visibility for a 744 pt regular window. An explicit `columnVisibility: .all` does open it side by side (iOS 18.6 and 27.0); the workspace passes no column visibility and keeps the platform default.

### Menu bar

- Replacing `.saveItem` removes the standard File > Close, so `KeeForgeCommands` re-adds Close Window (Cmd-W). The macOS lock guarantee and `MacWindowCloseGuard` assume that shortcut exists.
- Every item is disabled when it cannot apply (locked, read-only, no selection). Enablement for Edit and Delete comes from the same view-model properties the action uses.
- Copy Password goes through `EntrySecretAction` and revalidates the active session after authentication.

## Tests

- Persistent cloud sync controls, repeated syncs, policy changes, and warning state: `DatabaseViewModelCloudSyncTests`. The status popover workflow is covered by `CloudUnlockSmokeUITests` and `MacWebDAVSmokeUITests`.
- Mac automatic prompts, their trigger notifications, and queued-event invalidation: `MacBiometricAutoUnlockTests`.
- Routing and launch order: `AppRoutingCoordinatorTests`. Menu password copy: `EntrySecretActionTests`. Lock triggers: `MacLockMonitorTests`, `MacWindowCloseGuardTests`, `AutoLockTests`. iOS window activity forwarding: `IOSUserActivityTests`; real editor typing, scrolling, button taps, and subsequent idle locking: `AutoLockActivityUITests`.
- Mac list selection and keyboard wiring exists only as UI: `MacSmokeUITests` (the `testDownArrow…` and double-click cases) and `MacListKeyboardNavigationUITests`.
- Sidebar custom-icon data and recycle-bin icon projection: the macOS cases in `GroupIconViewTests`.
- Which sidebar widths count as the preference: `MacSidebarWidthSamplerTests`. Divider restoration across repeated lock/unlock cycles: `MacSmokeUITests.testSidebarWidthSurvivesRepeatedLockUnlockCycles`; native split-view layout requires the UI test.
- Root navigation changes ripple into `DatabaseListView`, `UnlockView`, and both UI suites; rerun the smallest affected class from `../../KeeForgeUITests/AGENTS.md`.

## See also

- `../ViewModels/AGENTS.md`: routing, workspace state, lock and auto-unlock eligibility
- `../Views/AGENTS.md`: shared UI rules and the Mac row-matching rule
- `../Services/AppSupport/AGENTS.md`: `MacLockMonitor`, `MacWindowCloseGuard`, quick access
- `../../KeeForgeMac/README.md`, `../../KeeForgeMac/SECURITY.md`, `../../KeeForgeMacUITests/AGENTS.md`
