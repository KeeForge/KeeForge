# App

**Scope:** app startup, scene phase, the iOS adaptive root shell that connects the database list to one active session, the SwiftUI pieces the Mac database windows host, and shared SwiftUI presentation. The Mac AppKit shell, its windows, menus, quit and workspace controllers are in `../../KeeForgeMac/AGENTS.md`. Compiled into `KeeForge` and `KeeForgeMac`, not the AutoFill targets.

## Ownership

Keep scene and platform adapters here and lifecycle decisions in the owning view model or service. Do not hide an app-wide state transition inside a view.

- `KeeForgeApp` owns the iOS lifecycle and its `DatabaseSessionStore`, `DatabaseListViewModel`, and `AppRoutingCoordinator`; `AppRootView` is the iOS shell only. On Mac, `../../KeeForgeMac/App/AppDelegate` and `MacWindowCoordinator` own the session store and one window per open database; their rules are in `../../KeeForgeMac/AGENTS.md`.
- The app owner (`KeeForgeApp` on iOS, `AppDelegate` on Mac) installs database-list reconciliation, forced retirement, and AutoFill enablement refresh hooks when it constructs the shared models; these hooks never depend on a mounted root.
- On iOS, launch order, incoming-URL classification, and Open/Close Database transitions are decided by `AppRoutingCoordinator`, which owns a `TOTPEnrollmentCoordinator` for link parsing, destination binding, expiry, and enrollment presentation (see `../ViewModels/AGENTS.md`). `AppRootView` only adapts the result to SwiftUI presentation.
- Auto-unlock is attempted in one place per platform: `.biometricAutoUnlock(_:)` on the iOS scene shells, and `MacBiometricAutoUnlockObserver` hosted once per database window by `MacDatabaseRootView` on macOS. Eligibility is `DatabaseViewModel.isEligibleForBiometricAutoUnlock`.
- Compact navigation and the group list compile only on iOS; the shared saving overlay and group/entry sheet content remain available on both platforms.
- `RegularDatabaseWorkspaceView` and `RegularDatabaseScene` own the iPad workspace and compile only on iOS.
- `MacWorkspacePresentationHost` wraps the native split representable once and owns the saving overlay and command request observers. The window controller owns `MacWorkspaceSheets` and `MacWorkspaceAlerts`; SwiftUI only supplies the hosted form content. The entry editor is not one of its sheets: the detail column shows the presentation's inline editor in place of the detail. Its identity must stay outside column revision keys and selection branches. The detail column takes only the database, the presentation object and the window's `MacAttachmentPreviewController`, and has no banners: on Mac, save and sync problems live in the sidebar status card and the notices above the entry list (`MacDatabaseStatus`). The split representable ignores the top safe area so the columns run under the titlebar and inset from their own safe areas; the host must add no top inset of its own.

## Invariants

### Scene phase and locking

- Backgrounding always shows the capture shield. On iOS it locks only when `SettingsService.lockOnBackground` is on; otherwise the `autoLockTimeout` check runs on the next activation.
- The scene-phase `.background` lock path is iOS-only; `MacLockMonitor` applies the Mac policy, where minimize and hide do not lock.
- Scene activation, iOS backgrounding, Mac system lock callbacks, and iOS foreground activity forward through `DatabaseSessionStore` to every stored session. Mac window activity resets only the registered database session; Mac activation evaluates existing deadlines without renewal. The app supplies that store to all Settings entry points through the environment; per-database AutoFill refresh looks up the toggled database's session by ID.
- iOS observes touches across the main window (including sheets) and text-field/text-view edits through `IOSUserActivityObserver`. Only foreground activity resets the inactivity timer; its passive recognizer must never delay, cancel, or prevent normal controls and scrolling.
- On the compact shell only a manual lock calls `VaultCloseTransition.coverCurrentFrame()`, immediately before the closing state change. An automatic lock can coincide with backgrounding, and a snapshot added then is what iOS would capture for the app switcher.
- Pending AutoFill uploads drain on foreground activation (iOS scene phase, and `MacLockMonitor.onDidBecomeActive` on macOS) and on the extension's Darwin notification. Both go through `DatabaseListViewModel.drainPendingUploadsOnAppActive()`; application-installed hooks refresh the affected open sessions after a drain.
- A change to background/foreground behaviour needs checking in both shells together with AutoFill cache refresh and pending-upload drain timing.

### Launch and presentation

- Google Drive reconnect in both iOS layouts must verify the bound account and file before clearing a reconnect error. A fenced Drive write uses the Cloud Recovery banner and encrypted export action.

- Open cloud databases keep Sync Now below the iPad sidebar title and in the Mac status card (the detail toolbar while the Mac sidebar is hidden). On iPhone only a status badge sits beside the root title and scrolls away with it (a spinner while syncing, a warning whose popover offers Sync Now), and pulling a cloud list down syncs on every iOS layout. Skipped-check, last-sync, pending-upload, and result text lives in its status popover; choosing a future sync policy never claims the current open skipped a check. Sync enablement comes from `DatabaseViewModel.canSyncCloudNow`.
- Unlock, unlocking, and unlocked are one selected-database flow. Compact presents unlock as a sheet over the list and swaps to the session once unlocked; regular renders all three states inline in the detail column. After an automatic lock (`DatabaseViewModel.staysSelectedAfterLock`), compact presents the database's unlock page again so auto-unlock can run; a manual or system lock returns to the list.
- Quick Launch waits until the What's New sheet (and the Mac transition notice) is dismissed, so two launch presentations never compete.
- SwiftUI drops a presentation raised while another sheet is dismissing. That is why deferred presentations wait 450 ms and why the conflicted-upload notice is a banner, not an alert: it is due at unlock, while the compact unlock sheet is dismissing.
- The iOS Settings sheet is attached above the root so it survives the lock/unlock root swap. It exists for the iPad app running on a Mac, where the sidebar gear is hidden and the system Settings item opens a compatibility window.
- On iOS, session-provider closures capture the reference-type session store and read `activeSession` when invoked. The iOS app keeps at most one session: replacement retires the locked source before opening the destination; creation, returning to the list, and list removal force retirement at the point the session is dropped.

### Auto-unlock

- On iOS, one attempt per `lockCycleID`, and only while `scenePhase == .active`: LocalAuthentication fails with `LAError.notInteractive` for a caller that is not foreground-active, which would burn the cycle's attempt on an error screen.
- An attempt that returns `.promptUnavailable` showed no UI and gives its lock cycle back.
- The attempt is claimed on `DatabaseViewModel` (`claimBiometricAutoUnlockAttempt`), not in view state. The scenes show the opening screen for a locked database only while `isAwaitingBiometricAutoUnlock`, so a cancelled or failed prompt hands the screen to the unlock form instead of leaving a spinner up.
- On Mac, attempt only when the session mounts in a foreground key window or that window/app returns to the foreground, including a screen unlock or session switch back while KeeForge stays active (`MacBiometricAutoUnlockController.startObserving`). Never trigger from a lock-cycle change. Defer past activation observers and recheck eligibility, window visibility, attached sheets, and the captured lock cycle before prompting. Cancellation or fallback consumes the cycle; the password form stays available. Automatic attempts share one app-wide gate and require the registered window to resolve to the observer's session, with restoration suppressed. Pending work is invalidated on unmount.
- The Mac observer lives above the locked/unlocked view switch, keyed by session. Mounting it counts as opening, so placing it inside a view that a lock replaces would prompt on every automatic lock while the window is frontmost.
- `BiometricAutoUnlockPolicy` disables auto-unlock for the iOS build running on Mac or Vision Pro, because `active` does not prove the compatibility window is frontmost. Those keep the explicit biometric action in `UnlockView`.

### Layout changes (iPhone Duo, iPad resizing)

- Opening or closing an iPhone Duo, and resizing an iPad window, flips the size class and rebuilds every view under the root. `AppRootView` applies the new layout one update behind the size class, after `DatabaseWorkspaceState.adaptNavigation(toRegularLayout:)` has carried the place across, and passes its applied size class down so no view sees the next layout early.
- Anything that must survive the switch lives on `DatabaseWorkspaceState`, never in a shell's `@State`: the navigation path (compact stack or regular sidebar), the selected entry, search, selection mode, and the open editor (`openEditor`). Both shells present `openEditor`: compact pushes it as the path's `.editor` route, regular hosts it in the detail column and keeps `.editor` and entries out of its sidebar path. Never present the compact editor with `navigationDestination(item:)` at the stack's root: popping it replaces the path, dropping the user back to the vault root.
- A layout switch is not a scene-phase change. It never locks or shows the capture shield unless iOS also backgrounds the app.
- `-ui-testing-layout-switch` (DEBUG only) shows a control that switches layouts in-app; no simulator can open or close a Duo from a test (`../../KeeForgeUITests/AGENTS.md`).

### iPad workspace

- Successful New Entry completion selects the saved entry through `revealEntry` in both regular shells, including a changed destination group. Cancel, edit, and Save and Lock keep their existing selection behavior.
- Editors (New Entry, Duplicate, Edit Group, Edit Entry) are hosted in the detail column, not pushed into the narrow sidebar. An open editor keeps its unsaved work: later requests are ignored while one is up.
- iPad mini in portrait starts with the sidebar collapsed behind the system "Show Sidebar" button. That is the platform's default visibility for a 744 pt regular window. An explicit `columnVisibility: .all` does open it side by side (iOS 18.6 and 27.0); the workspace passes no column visibility and keeps the platform default.

## Tests

- Persistent cloud sync controls, repeated syncs, policy changes, and warning state: `DatabaseViewModelCloudSyncTests`. The iOS status popover workflow is covered by `CloudUnlockSmokeUITests`; the Mac status card's Sync Now by `MacWebDAVSmokeUITests`.
- Mac automatic prompts, their trigger notifications, queued-event invalidation, and the foreground check that any attached sheet refuses: `MacBiometricAutoUnlockTests`.
- Single-session routing and launch integration: `AppRoutingCoordinatorTests`. Enrollment lifetime, destination validation and deferred presentation: `TOTPEnrollmentCoordinatorTests`. Lock triggers shared with iOS: `AutoLockTests`. Multi-session event delivery, reference reconciliation, view-independent list retirement and targeted activity: `DatabaseSessionStoreTests`; list mutations and AutoFill refresh wiring: `DatabaseListViewModelTests`; Settings effects: `AppSettingsViewModelTests`. iOS window activity forwarding: `IOSUserActivityTests`; real editor typing, scrolling, button taps, and subsequent idle locking: `AutoLockActivityUITests`. Mac shell tests: `../../KeeForgeMac/AGENTS.md`.
- Root navigation changes ripple into `DatabaseListView`, `UnlockView`, and both UI suites; rerun the smallest affected class from `../../KeeForgeUITests/AGENTS.md`.

## See also

- `../ViewModels/AGENTS.md`: routing, workspace state, lock and auto-unlock eligibility
- `../Views/AGENTS.md`: shared UI rules and the Mac row-matching rule
- `../Services/AppSupport/AGENTS.md`: `MacLockMonitor`, `MacWindowCloseGuard`, quick access
- `../../KeeForgeMac/AGENTS.md`: Mac windows, menus, quit, workspace controllers and their tests
- `../../KeeForgeMac/README.md`, `../../KeeForgeMac/SECURITY.md`, `../../KeeForgeMacUITests/AGENTS.md`
