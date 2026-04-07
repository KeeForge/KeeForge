#!/bin/bash
set -euo pipefail

echo "📦 Installing XcodeGen..."
if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$(pwd)}}"

echo "🛠️ Preparing build config..."
BOOTSTRAP_LOCAL_CONFIG_FROM_ENV=1 "$REPO_ROOT/ci_scripts/prepare_build_config.sh" "$REPO_ROOT"

echo "⚙️ Generating Xcode project..."
cd "$REPO_ROOT"
xcodegen generate

echo "✅ Project generated successfully"
