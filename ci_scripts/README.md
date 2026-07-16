# CI Scripts

This folder holds small scripts used by Xcode Cloud and local build setup.

## Current Script

- `prepare_build_config.sh` validates `BuildConfig.local.xcconfig`, stamps `BuildMetadata.xcconfig` with the current git hash, and can bootstrap the local config from environment variables in CI.
- `ci_post_clone.sh` installs XcodeGen, prepares the build config, and regenerates the Xcode project after checkout.
- `run_kdbx_compatibility_gate.sh` runs the KDBX artifact test, exports generated `.kdbx` attachments from the `.xcresult`, and validates them with `keepassxc-cli`. This is a required local release gate; Xcode Cloud does not install KeePassXC. For artifacts with `expectedAttachments` in the manifest (currently the `attachments.kdbx`-derived artifacts), it also resolves each entry via `keepassxc-cli search`, runs `keepassxc-cli attachment-export`, and compares the exported file's SHA-256 against the manifest value; the script prints how many attachment checks passed alongside the overall artifact count. The KeeOTP artifact retains all raw source variants for the XCTest compatibility matrix, but probes a standard entry externally because KeePassXC 2.7.12 does not expose those KeeOTP fields through its XML reader/search path.
- The artifact set includes a Twofish-256-CBC database, providing an external KeePassXC opener check for KeeForge's cipher-preserving output.
- `make_appstore_screenshots.py` formats raw screenshots from `build/screenshots` into App Store-ready images in `build/appstore`.

## Guidance

- Keep these scripts deterministic and noninteractive.
- If CI needs new generated files or dependencies, add them here instead of assuming the checked-in `.xcodeproj` is current.
- `BuildConfig.xcconfig` is a checked-in include file, not a generated source of truth.
- Local developers should copy `BuildConfig.local.example.xcconfig` to `BuildConfig.local.xcconfig`, fill in `DROPBOX_APP_KEY`, and optionally add `ONEDRIVE_CLIENT_ID` to test OneDrive OAuth.
- Xcode Cloud can provide `DROPBOX_APP_KEY` and `ONEDRIVE_CLIENT_ID` as environment variables for release archives; otherwise `ci_post_clone.sh` falls back to CI-only placeholders so project generation still succeeds.
- GitHub Actions can keep using simulator-safe placeholder values to materialize `BuildConfig.local.xcconfig`; the app treats the CI placeholders as cloud providers disabled for real sign-in.
- To run the KDBX compatibility gate locally, install KeePassXC or set `KEEPASSXC_CLI=/path/to/keepassxc-cli`, then run `ci_scripts/run_kdbx_compatibility_gate.sh`. Override `KDBX_COMPAT_DESTINATION` if the default `iPhone 17 Pro` simulator is unavailable.
- To regenerate App Store image composites after exporting raw screenshot PNGs into `build/screenshots`, run `ci_scripts/make_appstore_screenshots.py`.
