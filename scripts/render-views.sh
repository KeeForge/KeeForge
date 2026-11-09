#!/bin/bash
# Renders ViewRenderTests' PNGs in every shipped language on one simulator,
# building once. Usage: scripts/render-views.sh [simulator-udid] [lang ...]
# Output: <main checkout>/scratch/view-renders/<timestamp>/<lang>/*.png
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
main="$(git -C "$repo" worktree list --porcelain | awk 'NR==1{print $2}')"
sim="${1:-$(xcrun simctl list devices available | awk -F'[()]' '/iPhone/{print $2; exit}')}"
shift || true
langs=("$@")
[ ${#langs[@]} -eq 0 ] && langs=(en de fr es zh-Hans zh-Hant ja it ru)
out="$main/scratch/view-renders/$(date +%Y%m%d-%H%M%S)"
dd="$main/scratch/dd-render"
mkdir -p "$out"
region() { case "$1" in en) echo US;; de) echo DE;; fr) echo FR;; es) echo ES;; zh-Hans) echo CN;; zh-Hant) echo TW;; ja) echo JP;; it) echo IT;; ru) echo RU;; *) echo US;; esac; }

xcodebuild build-for-testing -project "$repo/KeeForge.xcodeproj" -scheme KeeForge \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$dd" -quiet > "$out/build.log" 2>&1 \
  || { echo "build failed: $out/build.log"; grep -E "error:" "$out/build.log" | sort -u | head -20; exit 1; }

status=0
for lang in "${langs[@]}"; do
  TEST_RUNNER_VIEW_RENDER_DIR="$out" xcodebuild test-without-building -project "$repo/KeeForge.xcodeproj" -scheme KeeForge \
    -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$dd" \
    -only-testing:KeeForgeTests/ViewRenderTests -testLanguage "$lang" -testRegion "$(region "$lang")" \
    > "$out/test-$lang.log" 2>&1 || { echo "render failed for $lang: $out/test-$lang.log"; status=1; }
done
echo "$out"
exit $status
