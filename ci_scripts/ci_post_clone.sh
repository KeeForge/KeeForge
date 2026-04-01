#!/bin/bash
set -e

echo "📦 Installing XcodeGen..."
brew install xcodegen

echo "🔖 Stamping git commit hash..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
echo "GIT_COMMIT_HASH = $(git rev-parse --short HEAD)" > BuildConfig.xcconfig

echo "⚙️ Generating Xcode project..."
xcodegen generate

echo "✅ Project generated successfully"
