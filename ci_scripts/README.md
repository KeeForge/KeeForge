# CI Scripts

This folder holds small scripts used by Xcode Cloud.

## Current Script

- `ci_post_clone.sh` installs XcodeGen, stamps `BuildConfig.xcconfig` with the current git hash, and regenerates the Xcode project after checkout.

## Guidance

- Keep these scripts deterministic and noninteractive.
- If CI needs new generated files or dependencies, add them here instead of assuming the checked-in `.xcodeproj` is current.
- Local builds may also touch `BuildConfig.xcconfig`; do not treat that file as a hand-edited source of truth.
