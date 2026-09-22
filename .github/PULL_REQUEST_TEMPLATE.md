# Summary

<!-- What does this PR change, and why? Link related issues with "Fixes #123". -->

# Changes

-

# Testing

<!-- How was this verified? List the iOS and/or macOS test slices you ran, e.g.
     xcodebuild test … -only-testing:KeeForgeTests/DatabaseViewModelTests -->

-

# Checklist

- [ ] Updated `CHANGELOG.md` under `## Unreleased` when the change is user-facing
- [ ] Ran `xcodegen generate` after adding/removing/moving source files
- [ ] Updated the nearest folder-local `README.md` if the folder's map changed
- [ ] Localized new UI strings in all shipped locales listed in AGENTS.md and ran `LocalizationTests`
- [ ] Kept AutoFill extension target membership/imports in sync for shared code
- [ ] Updated `KDBXCompatibilityTests` if parser/writer/save behavior changed
- [ ] Preserved accessibility identifiers or updated the affected UI tests
- [ ] Ran a `KeeForgeMacTests` slice when shared or Mac behavior changed
