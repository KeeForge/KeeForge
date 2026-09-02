#!/usr/bin/env bash
# Verify a built KeeForge Mac app without building, signing, or reading secrets.
#
# This is deliberately an artifact-level check. Source-level compilation
# conditions and runtime gates are useful, but they cannot prove what landed in
# an exported app. The public Sparkle key is checked only for presence; its
# value is never printed.

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  verify_mac_artifact.sh --channel mas|direct --app PATH \
    --architectures arm64,x86_64

The architecture list is required so a single-architecture exception is an
explicit product decision rather than an accidental release.
USAGE
}

die() { echo "error: $*" >&2; exit 1; }
need_command() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

CHANNEL=""
APP_PATH=""
EXPECTED_ARCHITECTURES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --app) APP_PATH="${2:-}"; shift 2 ;;
    --architectures) EXPECTED_ARCHITECTURES="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$CHANNEL" == "mas" || "$CHANNEL" == "direct" ]] \
  || { usage; die "--channel must be mas or direct"; }
[[ -n "$APP_PATH" && -d "$APP_PATH" ]] || die "--app must name an existing .app directory"
[[ -n "$EXPECTED_ARCHITECTURES" ]] || { usage; die "--architectures is required"; }
[[ "$APP_PATH" == *.app ]] || die "--app must name a .app directory"

need_command codesign
need_command find
need_command grep
need_command lipo
need_command otool
need_command strings
need_command file

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || die "missing Contents/Info.plist"

plist_value() {
  local key="$1"
  /usr/libexec/PlistBuddy -c "Print :${key}" "$INFO_PLIST" 2>/dev/null || true
}

EXECUTABLE_NAME="$(plist_value CFBundleExecutable)"
[[ -n "$EXECUTABLE_NAME" ]] || die "CFBundleExecutable is missing"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}"
[[ -f "$EXECUTABLE_PATH" ]] || die "CFBundleExecutable does not exist"

plist_value_at() {
  local plist="$1" key="$2"
  /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null || true
}

# Normalise both comma-separated and whitespace-separated input, then compare
# exact sets. This catches both a missing Intel slice and an unexpected slice.
normalise_architectures() {
  tr ',' ' ' <<<"$1" | awk '{$1=$1; print}' | tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd ' ' -
}

EXPECTED_ARCHITECTURES="$(normalise_architectures "$EXPECTED_ARCHITECTURES")"
[[ -n "$EXPECTED_ARCHITECTURES" ]] || die "--architectures must contain at least one architecture"
ACTUAL_ARCHITECTURES="$(lipo -archs "$EXECUTABLE_PATH" 2>/dev/null || true)"
ACTUAL_ARCHITECTURES="$(normalise_architectures "$ACTUAL_ARCHITECTURES")"

# Every signed executable bundle must retain the hardened runtime. Inspecting
# entitlements through a temporary file avoids accidentally printing a value
# while still checking the complete plist. The temporary file is removed on
# every exit path.
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keeforge-artifact.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

bundle_hardening() {
  local bundle="$1" metadata entitlements
  metadata="$(codesign -dvv "$bundle" 2>&1)" \
    || die "code signature is invalid"
  grep -Eq 'flags=.*\(.*runtime.*\)' <<<"$metadata" \
    || die "hardened runtime is missing"

  entitlements="${TMP_DIR}/entitlements.plist"
  if codesign -d --entitlements - --xml "$bundle" >"$entitlements" 2>/dev/null; then
    if grep -q 'com.apple.security.cs\.' "$entitlements" \
      || grep -q 'get-task-allow' "$entitlements"; then
      die "code-signing exception entitlement is present"
    fi
  fi
}

codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 \
  || die "app code signature is invalid"

ROOT_ENTITLEMENTS="${TMP_DIR}/root-entitlements.plist"
codesign -d --entitlements - --xml "$APP_PATH" >"$ROOT_ENTITLEMENTS" 2>/dev/null \
  || die "app entitlements are unavailable"
grep -q 'com.apple.security.app-sandbox' "$ROOT_ENTITLEMENTS" \
  || die "app sandbox entitlement is missing"
bundle_hardening "$APP_PATH"

while IFS= read -r nested_bundle; do
  [[ -n "$nested_bundle" ]] || continue
  bundle_hardening "$nested_bundle"
  case "$nested_bundle" in
    *.appex)
      nested_entitlements="${TMP_DIR}/nested-entitlements.plist"
      codesign -d --entitlements - --xml "$nested_bundle" >"$nested_entitlements" 2>/dev/null \
        || die "AutoFill extension entitlements are unavailable"
      grep -q 'com.apple.security.app-sandbox' "$nested_entitlements" \
        || die "AutoFill extension sandbox entitlement is missing"
      ;;
  esac
done < <(find "${APP_PATH}/Contents" -type d \( -name '*.app' -o -name '*.appex' -o -name '*.xpc' \) -print)

# Check the root app and KeeForge-owned nested app/appex executables. Sparkle
# helper apps are intentionally excluded here; they are third-party payloads,
# not part of KeeForge's architecture/product-support promise.
declare -a OWNED_EXECUTABLES=("$EXECUTABLE_PATH")
while IFS= read -r nested_bundle; do
  [[ -n "$nested_bundle" ]] || continue
  case "$nested_bundle" in
    */Sparkle.framework/*) continue ;;
  esac
  nested_plist="${nested_bundle}/Contents/Info.plist"
  nested_name="$(plist_value_at "$nested_plist" CFBundleExecutable)"
  nested_executable="${nested_bundle}/Contents/MacOS/${nested_name}"
  [[ -n "$nested_name" && -f "$nested_executable" ]] \
    || die "nested bundle executable is missing"
  OWNED_EXECUTABLES+=("$nested_executable")
done < <(find "${APP_PATH}/Contents" -type d -name '*.appex' -print)

for owned_executable in "${OWNED_EXECUTABLES[@]}"; do
  owned_architectures="$(lipo -archs "$owned_executable" 2>/dev/null || true)"
  owned_architectures="$(normalise_architectures "$owned_architectures")"
  [[ "$owned_architectures" == "$EXPECTED_ARCHITECTURES" ]] \
    || die "KeeForge executable architectures do not match the requested release set"
done

# Collect every Mach-O binary in the exported artifact for dependency checks.
# Sparkle's own helpers are skipped below: they are expected to contain Sparkle
# and must not make the direct build fail its StoreKit exclusion check.
declare -a MACHO_BINARIES=()
while IFS= read -r binary; do
  [[ -n "$binary" ]] || continue
  case "$binary" in
    */Sparkle.framework/*) continue ;;
  esac
  if file -b "$binary" 2>/dev/null | grep -q 'Mach-O'; then
    MACHO_BINARIES+=("$binary")
  fi
done < <(find "${APP_PATH}/Contents" -type f -print)

OTool_DEPENDENCIES="$(otool -L "$EXECUTABLE_PATH" 2>/dev/null || true)"
EXECUTABLE_STRINGS="$(strings "$EXECUTABLE_PATH" 2>/dev/null || true)"
SPARKLE_PATHS="$(find "${APP_PATH}/Contents" -iname '*sparkle*' -print 2>/dev/null || true)"
SPARKLE_FRAMEWORK_PATHS="$(find "${APP_PATH}/Contents" -type d -name 'Sparkle.framework' -print 2>/dev/null || true)"
SPARKLE_UPDATER_PATHS="$(find "${APP_PATH}/Contents" -type d \( \
  -iname 'Autoupdate.app' -o \
  -iname 'InstallerLauncher.xpc' -o \
  -iname 'Downloader.xpc' -o \
  -iname '*sparkle*.xpc' \
  \) -print 2>/dev/null || true)"
STOREKIT_PATHS="$(find "${APP_PATH}/Contents" -iname '*storekit*' -print 2>/dev/null || true)"
SPARKLE_COMPONENTS="${SPARKLE_FRAMEWORK_PATHS}${SPARKLE_UPDATER_PATHS}"
FEED_URL="$(plist_value SUFeedURL)"
PUBLIC_KEY="$(plist_value SUPublicEDKey)"

case "$CHANNEL" in
  mas)
    [[ -z "$SPARKLE_FRAMEWORK_PATHS" ]] || die "MAS artifact contains Sparkle.framework"
    [[ -z "$SPARKLE_UPDATER_PATHS" ]] || die "MAS artifact contains a Sparkle updater component"
    ! grep -Eiq 'sparkle|SPUStandardUpdater|Check for Updates|SUFeedURL|SUPublicEDKey' \
      <<<"${OTool_DEPENDENCIES}" \
      || die "MAS executable links or names Sparkle"
    ! grep -Eiq 'SPUStandardUpdater|Check for Updates|SUFeedURL|SUPublicEDKey' \
      <<<"${EXECUTABLE_STRINGS}" \
      || die "MAS executable contains Sparkle updater UI"
    for binary in "${MACHO_BINARIES[@]}"; do
      binary_dependencies="$(otool -L "$binary" 2>/dev/null || true)"
      ! grep -Eiq 'sparkle|SPUStandardUpdater' <<<"$binary_dependencies" \
        || die "MAS artifact links Sparkle"
    done
    [[ -z "$FEED_URL" ]] || die "MAS artifact contains a Sparkle feed URL"
    [[ -z "$PUBLIC_KEY" ]] || die "MAS artifact contains a Sparkle public key"
    ;;
  direct)
    [[ -n "$SPARKLE_PATHS" ]] || die "direct artifact does not contain Sparkle"
    grep -Eiq 'sparkle' <<<"$OTool_DEPENDENCIES" \
      || die "direct executable does not link Sparkle"
    [[ "$FEED_URL" == https://* ]] || die "direct artifact feed URL is not HTTPS"
    [[ -n "$PUBLIC_KEY" ]] || die "direct artifact public update key is missing"
    [[ -z "$STOREKIT_PATHS" ]] || die "direct artifact contains a StoreKit bundle"
    for binary in "${MACHO_BINARIES[@]}"; do
      binary_dependencies="$(otool -L "$binary" 2>/dev/null || true)"
      ! grep -Eiq 'StoreKit' <<<"$binary_dependencies" \
        || die "direct artifact links StoreKit"
    done
    ;;
esac

echo "channel=${CHANNEL}"
echo "app=${APP_PATH}"
echo "architectures=${ACTUAL_ARCHITECTURES}"
echo "owned_executables_checked=${#OWNED_EXECUTABLES[@]}"
echo "sandbox=true"
echo "hardened_runtime=true"
echo "sparkle_present=$([[ -n "$SPARKLE_COMPONENTS" ]] && echo true || echo false)"
echo "storekit_present=$([[ -n "$STOREKIT_PATHS" ]] && echo true || echo false)"
echo "feed_url_present=$([[ -n "$FEED_URL" ]] && echo true || echo false)"
echo "public_update_key_present=$([[ -n "$PUBLIC_KEY" ]] && echo true || echo false)"
if [[ -n "$FEED_URL" ]]; then
  echo "feed_url=${FEED_URL}"
fi
echo "result=pass"
