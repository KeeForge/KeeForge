# CI Scripts

This folder holds small scripts used by Xcode Cloud and local build setup.

## Current Script

- `prepare_build_config.sh` validates `BuildConfig.local.xcconfig`, stamps `BuildMetadata.xcconfig` with the current git hash, and can bootstrap the local config from environment variables in CI.
- `ci_post_clone.sh` installs XcodeGen, prepares the build config, and regenerates the Xcode project after checkout.

## Guidance

- Keep these scripts deterministic and noninteractive.
- If CI needs new generated files or dependencies, add them here instead of assuming the checked-in `.xcodeproj` is current.
- `BuildConfig.xcconfig` is a checked-in include file, not a generated source of truth.
- Local developers should copy `BuildConfig.local.example.xcconfig` to `BuildConfig.local.xcconfig` and fill in `DEVELOPMENT_TEAM` plus `DROPBOX_APP_KEY`.
- Xcode Cloud should provide `DEVELOPMENT_TEAM` and `DROPBOX_APP_KEY` environment variables so `ci_post_clone.sh` can materialize `BuildConfig.local.xcconfig`.
- GitHub Actions uses simulator-safe placeholder values to materialize `BuildConfig.local.xcconfig`; this keeps CI green without requiring real signing or Dropbox secrets.
