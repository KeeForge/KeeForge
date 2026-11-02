# Summary

<!-- What does this PR change, and why? Link related issues with "Fixes #123". -->

# Testing

<!-- The iOS and macOS test slices you ran, e.g.
     xcodebuild test … -only-testing:KeeForgeTests/DatabaseViewModelTests -->

-

# Screenshots

<!-- Required for any UI change: iOS and macOS, one row per affected scenario
     (e.g. empty/error states, light/dark, iPad, AutoFill). Delete this section otherwise. -->

| Scenario | iOS | macOS |
| --- | --- | --- |
|  |  |  |

# Checklist

<!-- Check what applies; leave the rest unchecked. -->

- [ ] User-facing change: `CHANGELOG.md` updated, and iOS/macOS/AutoFill parity checked (differences noted above)
- [ ] UI change: screenshots for both platforms above, strings localized in all shipped locales (`LocalizationTests` run), accessibility identifiers preserved or UI tests updated
- [ ] Parser, writer, or save change: `KDBXCompatibilityTests` updated
- [ ] Files added, moved, or removed: `xcodegen generate` run, AutoFill target membership checked
- [ ] Invariant, ownership boundary, or test mapping changed: folder `AGENTS.md` updated
