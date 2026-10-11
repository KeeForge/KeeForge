# App Support Services

**Scope:** app-scoped helpers behind UI behavior and secondary surfaces: settings storage, clipboard, favicons, feedback, attachment previews, review and What's New prompts, and the Mac lock, window-close, and menu bar quick access services. Cross-service rules are in `../AGENTS.md`.

## Ownership

- `SettingsService`: where each preference is stored (app-local or App Group-shared). `AppSettingsViewModel` owns their live effects.
- `MacLockMonitor`: the macOS lock lifecycle. macOS has no "entered background" moment, so its triggers are what locks the vault there.
- `MacWindowCloseGuard`: settles unsaved work before a close that would leave no host window. `MacLockMonitor`'s last-window trigger fires after the close commits, too late to prompt.
- `MacQuickAccessController`: the opt-in status item, the quick-search panel, and the global shortcut, which exists only while the status item does.
- `WhatsNewPresentationService`: the curated feature catalog. Add one case before each feature-bearing release, written from `CHANGELOG.md` as user-facing copy.

## Invariants

### Target membership

- `MacLockMonitor`, `MacWindowCloseGuard`, `MacQuickAccessController`, and `MacGlobalHotKey` are excluded from the iOS app in `../../../project.yml`. Other Mac-only files compile everywhere behind `#if os(macOS)`.
- `SoftwareUpdateService` (Sparkle) compiles only with `KEEFORGE_DIRECT_DOWNLOAD`, and `StoreKitManager` only without it. `SoftwareUpdateServiceTests` therefore builds only with `project-direct.yml`.
- `SettingsService`, `FaviconService`, and `ClipboardService` are on the AutoFill allow-lists and must stay extension-safe on both platforms. That is why `SettingsService.MacHotKey` is an AppKit-free value type.

### Settings storage

- A setting the extension reads lives in the App Group suite: `clipboardTimeout`, `autoFillCopyTOTP`, `autoUnlockWithFaceID`, `quickAutoFillEnabled`, `passwordGeneratorOptions`. `showWebsiteIcons` is shared too, but no extension code reads it today. Everything else stays in `UserDefaults.standard`. Moving one changes what shipped installs read.
- `clipboardTimeout` is shared so the app and extension agree on expiry; its getter migrates the older app-local value on first read.
- `AuthenticationGracePeriod` defaults to Always Ask and is bounded at five minutes; do not add an unbounded option. `../Security/SecretAccessGate` reads it.

### Clipboard

- iOS: every copy carries a `UIPasteboard` expiration date and `.localOnly`, so the system expires it and it stays off Universal Clipboard. macOS has neither: a copy is marked `org.nspasteboard.ConcealedType` and cleared by an in-process timer.
- Both branches clear only while `changeCount` still matches the app's own write, so a later copy by the user is never clobbered.
- `clearOwnedContents()` runs on every lock. The single exception is iOS backgrounding (`../../ViewModels/AGENTS.md`), where the expiration date bounds the copy instead. macOS has no such bound, so a missed scrub there leaves the secret on the pasteboard.
- The AutoFill extension calls only the iOS branch (verification-code copy). The macOS timer would die with the extension process, so the coordinator gates the feature on `#if os(iOS)`; the Mac extension compiles the AppKit branch without calling it.

### Favicons

- Fetching is opt-in (`showWebsiteIcons`, default off) and goes only to `icons.duckduckgo.com`.
- The disk cache is a plaintext per-domain fingerprint of the vault. iOS keeps it in the App Group container; macOS keeps it in the app's own Application Support so the fingerprint stays out of shared storage. No extension code reads the cache today; keep the path code Foundation-only because the file is still compiled into both extensions.
- An icon being stored inside the database is fetched with `cachingToDisk: false` (`FaviconIconEncoder.downloadedIconData(for:)`): it is already kept encrypted, and a second plaintext copy would widen the fingerprint for nothing.
- Fetches use a dedicated ephemeral session, never `URLSession.shared`: its persisted Alt-Svc cache can leave CFNetwork hanging in a QUIC handshake on networks that drop UDP 443. See `sessionConfiguration()`.

### Feedback and temporary files

- `FeedbackSubmissionService` sends only on explicit submit, only to `feedback.keeforge.com`: the message, optional contact email with consent, an optional photo up to 5 MiB, and the error context of the failure being reported (category, code, details).
- That context comes from `DatabaseOpenFailure` and carries no file names, paths, or vault data. Do not attach anything else automatically.
- `AttachmentPreviewFileStore` files are plaintext attachment contents. They are removed on preview dismissal and on database lock, and `purgeOrphanedFiles()` at launch cleans up after a crash. A new consumer must call `remove(_:)`.

### Mac lock, window close, quick access

- Screen lock, screensaver, sleep, session resign, and the last host window closing lock unconditionally. App deactivation locks only under the strict `MacLockPolicy`.
- Under the strict policy, a deactivation caused by the app's own authentication prompt is held, not excused: it needs both a pending request (`BiometricService.isBiometricAuthInProgress`) and the system authentication UI in front (`ForegroundApplication.isSystemAuthenticationPrompt`). Any other application coming forward locks.
- When the request ends the hold settles: KeeForge is active again within `defaultReactivationGracePeriod`, or it locks.
- `MacLockMonitor.countRemainingHostWindows` is the one definition of a host window; `MacWindowCloseGuard` shares it. The guard proxies each window's delegate instead of replacing it.
- The quick-search panel is a non-activating `NSPanel` with `canBecomeMain == false`: it neither keeps a vault unlocked nor counts as the last window. It holds no entry data and only a reference to the active session, cleared when the database closes.
- The panel is outside `ScreenProtectionService`'s key-window sweep, so it sets its own `sharingType` from Block Screen Capture.
- Only the password copy activates KeeForge (LocalAuthentication needs the active app); the previous app is re-activated when the prompt ends, however it ends.
- The panel's key monitor leaves every key to the field while an input method is composing (`isComposingText(in:)`), because those keys confirm and cancel candidates.
- The global shortcut uses Carbon `RegisterEventHotKey`, the only public API that works sandboxed without the Accessibility permission. Registration fails rather than taking a combination another app holds.

### Prompts and notices

- `MacTransitionNoticeService` shows its sheet when the App Group list exists or the container cannot be resolved at all. A nil container means macOS denied the group to this build (another build shares the bundle id), which is exactly when the list is empty and the user needs the instructions.
- `MacAppSuggestionService` suggests the native app only when `ProcessInfo.isiOSAppOnMac` is true.
- `ReviewPromptService` no-ops outside App Store builds; macOS has no scene entry point, so the app injects `RequestReviewAction` through `requestReviewHandler`.
- `AutoFillStatusService.requestEnableAutoFill` returns false when the prompt closed with the provider still off; callers must report that so the tap does not look like a switch that reset itself.

## Tests

- `SettingsServiceTests`, `FaviconServiceTests`, `FaviconIconEncoderTests`, `FeedbackSubmissionServiceTests`, `AttachmentPreviewFileStoreTests`, `ReviewPromptServiceTests`, `WhatsNewPresentationServiceTests`, `AutoFillStatusServiceTests`.
- Mac: `MacLockMonitorTests`, `MacWindowCloseGuardTests`, `MacQuickAccessControllerTests`, `MacQuickSearchViewModelTests`, `MacTransitionNoticeServiceTests` (all `KeeForgeMacTests` only).
- `ClipboardService` has no class of its own; scrubbing on lock is covered in `AutoLockTests`.
- UI tests suppress the AutoFill tip unless `UI_TEST_SHOW_AUTOFILL_TIP=1` and force the Mac app banner with `UI_TEST_SHOW_MAC_APP_SUGGESTION=1`.

## See also

- `../AGENTS.md`, `../Security/AGENTS.md`
- `../../ViewModels/AGENTS.md`: lock and clipboard rules, `MacQuickSearchViewModel`
- `../../../KeeForgeMac/README.md`, `../../../KeeForgeMac/SECURITY.md`
