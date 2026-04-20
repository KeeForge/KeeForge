# Status

## 2026-04-18

- Added typed database-open failure classification so KeeForge now distinguishes expected auth/password failures from unexpected file, format, cloud, and biometric open failures.
- Replaced the old inline unlock error label with a richer failure card that offers retry, choose-different-file/back, copy-details, and send-feedback actions plus a privacy reassurance.
- Added an app-side feedback vertical slice:
  - `FeedbackSubmissionService` with a strict, conservative payload shape
  - a reusable `FeedbackComposerView`
  - Settings entry point plus unlock-error entry point
  - feedback endpoint `https://feedback.keeforge.com/api/feedback`
- Added targeted unit-test updates for the new failure model and feedback payload encoding.
- Regenerated `KeeForge.xcodeproj` after adding new source files.

## Verification

- `xcodegen generate` succeeded.
- `xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/KeeForgeDerived -only-testing:KeeForgeTests/DatabaseViewModelTests -only-testing:KeeForgeTests/FeedbackSubmissionServiceTests -quiet`
  - Build progressed into simulator launch, but CoreSimulator was unhealthy in this environment and died with `NSMachErrorDomain -308` / `CoreSimulatorService connection became invalid`, so the targeted tests could not complete.
