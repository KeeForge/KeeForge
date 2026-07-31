#!/bin/bash
set -euo pipefail

# Xcode Cloud runs this from ci_scripts/ and sets CI_PRIMARY_REPOSITORY_PATH only
# for the phases that check out source. The test-execution phases set neither it
# nor CI_WORKSPACE, so a $(pwd) fallback resolved to ci_scripts/ and doubled the path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$(dirname "$SCRIPT_DIR")}}"

# `ci_post_clone.sh` bootstraps BuildConfig.local.xcconfig, but CI_XCODEBUILD_ACTION
# is only guaranteed to be set for the xcodebuild-adjacent scripts. Re-run the
# validation here so an archive workflow missing DROPBOX_APP_KEY fails before it
# produces a binary carrying the CI placeholder. Those test-execution phases restore
# artifacts instead of re-running post-clone, so the gitignored local config that
# post-clone wrote may be absent — bootstrap it here as well.
echo "🔎 Validating build config for action: ${CI_XCODEBUILD_ACTION:-unknown}"
BOOTSTRAP_LOCAL_CONFIG_FROM_ENV=1 "$REPO_ROOT/ci_scripts/prepare_build_config.sh" "$REPO_ROOT"

echo "✅ Build config validated"
