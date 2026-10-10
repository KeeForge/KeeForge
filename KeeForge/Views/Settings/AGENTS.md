# Settings Views

**Scope:** app settings (iOS summary root and pushed screens, macOS tabbed window), feedback, What's New, the Mac transition notice, the database-list tip cards, support surfaces, and the DEBUG-only AutoFill store inspector. Folder-wide UI rules are in `../AGENTS.md`.

## Ownership

- `AppSettingsViewModel` owns preference persistence and live effects, account loading and sign-out, and favicon cache clearing. `SettingsView` connects it to the current session on appearance and session change, then calls `reload()`, which does not replay effects.
- Add a preference effect to the model with a headless test, not to a view `onChange`. `ci_scripts/validate_architecture.py` fails any `SettingsService.<property> =` assignment in `SettingsView.swift`.
- Every per-database AutoFill toggle goes through the `DatabaseListViewModel` passed in as `listViewModel` (`setAutoFillEnabled`), never `DatabaseListStore`. That instance carries the `autoFillEnabledRefreshHandler` bridge and the system-provider state, so this screen and the list's tip card cannot disagree.
- Summary wording for the iOS root is the pure `AppSettingsSummary`. `SupportKeeForgeSection` picks the support surface so call sites do not know the build channel.

## Invariants

### AutoFill settings

- A declined enable request is persistent footer text (`isAutoFillEnableRequestRejected`), never an alert, and the manual route into system Settings stays visible while the provider is off. The system can refuse the one-tap prompt and tears this sheet down when it closes.
- Copy Verification Code is iOS-only. The Mac extension supplies codes directly, and its timer-based clipboard clearing cannot outlive the extension process.
- Clear AutoFill Entries does not republish the open database; the user asked for an empty store.
- On macOS the store reports no incremental updates, so every write replaces the whole store and suggestions come from one database at a time. The Databases footer says so when more than one is selected (`../../Services/AutoFill/CredentialIdentityStoreManager.swift`).
- The iOS root's AutoFill row says nothing about the system provider until its state is known, and the root refreshes that state itself.
- The macOS Security tab's biometric label describes the AutoFill extension only; the Mac app never auto-unlocks.

### Layout

- Every macOS tab is pinned to `MacSettingsPane`'s fixed size, not a minimum. A settings window sizes to its widest tab and `Form` footers each want a full line, so a free-sizing window opens far too wide.
- The Mac window selects Security explicitly so it does not restore the last tab.
- The support section stays inline on the iOS root; a tip jar behind a row is not seen.
- A direct-download build must not show the StoreKit tip jar (no receipt to purchase against); it links to GitHub Sponsors.
- `MacTransitionNoticeView` copy is static. It must read correctly whether the list behind it is intact, stale, or empty, so it never names a database or a count.
- `MacShortcutRecorder` sets the controller's `isRecordingShortcut` so the live global shortcut is released while recording.
- What's New rows with a link are `.contain` containers so the link stays individually actionable; others combine.

### AutoFill store inspector

- Both inspector files are wholly `#if DEBUG`, shown only for the `-autofill-store-inspector` launch argument. It reads store metadata only, never vault contents, and enumerates off the main actor.
- A pending or failed enumeration renders its own status or error, never a zero count.
- Simulators return an empty enumeration even though writes persist, and macOS cannot enumerate either. Inspector counts and enumerate-then-mutate store maintenance are only meaningful on a physical device, which is why `AutoFillStoreUITests` runs on one.

## Tests

- `AppSettingsViewModelTests`, `AppSettingsSummaryTests`, `AutoFillStoreInspectorGroupingTests`, `FeedbackSubmissionServiceTests`.
- UI: `AutoFillTipUITests`, `MacAppSuggestionUITests`, `WhatsNewUITests`, `AutoFillStoreInspectorSmokeUITests`; `AutoFillStoreUITests` needs a provisioned device.

## See also

- `../AGENTS.md`, `../Components/AGENTS.md` (`SettingsSummaryRow`, `tipBannerCard()`)
- `../../ViewModels/AGENTS.md`, `../../Services/AutoFill/AGENTS.md`, `../../Services/AppSupport/AGENTS.md`
- `../../../KeeForgeMac/README.md`: why macOS suggestions cannot aggregate across databases
