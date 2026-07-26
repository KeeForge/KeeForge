#!/bin/bash
set -euo pipefail

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$(pwd)}}"

# `ci_post_clone.sh` bootstraps BuildConfig.local.xcconfig, but CI_XCODEBUILD_ACTION
# is only guaranteed to be set for the xcodebuild-adjacent scripts. Re-run the
# validation here so an archive workflow missing DROPBOX_APP_KEY fails before it
# produces a binary carrying the CI placeholder.
echo "🔎 Validating build config for action: ${CI_XCODEBUILD_ACTION:-unknown}"
"$REPO_ROOT/ci_scripts/prepare_build_config.sh" "$REPO_ROOT"

echo "✅ Build config validated"
