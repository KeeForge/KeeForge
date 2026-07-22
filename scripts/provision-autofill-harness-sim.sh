#!/usr/bin/env bash
#
# provision-autofill-harness-sim.sh
# =================================
#
# Provisions the dedicated "AutoFill store validation harness" simulator that the
# slice-03 XCUITests assume: a named iPhone-class simulator, booted, with the
# Debug KeeForge.app installed and KeeForge enabled as the system credential
# (AutoFill) provider. Everything except flipping the one Settings toggle is
# unattended and driven entirely through `xcrun simctl` (no Simulator.app needed).
#
# This file is the recipe doc for the scripts/ folder (there is no scripts/README).
#
# What it does
# ------------
#   1. Resolves the newest installed iOS simulator runtime and an iPhone-class
#      device type.
#   2. Reuses the harness device if it already exists; creates it otherwise.
#      Fails loudly if two devices share the harness name (ambiguous).
#   3. Boots it and waits for `simctl bootstatus`.
#   4. Builds (or accepts a prebuilt path to) the Debug KeeForge.app and installs
#      it with `simctl install`.
#   5. Opens the Settings app and prints the one manual step, then polls the app's
#      status-log channel until KeeForge reports it is enabled as the provider.
#
# Verification channel (fixed contract with the app side)
# -------------------------------------------------------
#   Launching the installed Debug build with the launch argument
#   `-autofill-store-status-log` makes it emit EXACTLY one line, via both stdout
#   (`print`) and NSLog (unified log):
#
#       KEEFORGE-AUTOFILL-STORE-STATUS: enabled=<true|false> enumeration=<available|unavailable>
#
#   This script reads that line from the simulator's unified log
#   (`simctl spawn <udid> log show`, the NSLog channel) after each relaunch and
#   succeeds once it sees `enabled=true`. If the installed build never emits the
#   line at all, the script fails with a "rebuild and reinstall" message instead
#   of looping forever — distinct from the "seen, but enabled=false" timeout case.
#
# Usage
# -----
#   scripts/provision-autofill-harness-sim.sh [--erase] [--app-path <path>] [--timeout <seconds>]
#
#   --erase             Erase the harness device before provisioning, for a
#                       from-scratch rebuild. NOTE: erasing wipes provider
#                       enablement, so you WILL have to flip the Settings toggle
#                       again (the script waits for it).
#   --app-path <path>   Install this prebuilt .app instead of building. Skips
#                       xcodebuild entirely.
#   --timeout <seconds> Verification poll timeout (default 300). Kept low when you
#                       want to exercise the failure path quickly.
#   -h | --help         Print usage and exit.
#
# The provider-enabled state persists on the device until it is erased, so after a
# first successful run subsequent runs verify immediately with no manual step.
# To re-verify at any time, just re-run the script (idempotent).
#
# Exit codes
# ----------
#   0   Success — KeeForge confirmed enabled=true.
#   2   Usage / bad flag.
#   3   Multiple devices share the harness name (ambiguous — delete the extras).
#   4   Build failure.
#   5   Install failure.
#   6   Installed build never emitted the status line (missing -autofill-store-log
#       support, or the app failed to launch) — rebuild and reinstall a Debug build.
#   7   Verification timeout — status line seen but never enabled=true; flip the
#       Settings toggle (Settings > General > AutoFill & Passwords > KeeForge).
#   8   Missing dependency (xcrun / jq).
#   9   Could not resolve a runtime or device type on this machine.
#   10  Bad --app-path (not a readable .app bundle).
#
# Internal / testing knobs (not part of the public interface)
# -----------------------------------------------------------
#   KEEFORGE_HARNESS_DEVICE_NAME   Override the device name (default
#                                  "KeeForge-AutoFill-Harness"). Used by the
#                                  plumbing dry-run so it never touches the real
#                                  harness device.
#   KEEFORGE_HARNESS_DEVICE_TYPE   Override the device type name (default
#                                  "iPhone 17 Pro").
#   KEEFORGE_HARNESS_DRY_RUN=1     Stop after boot + bootstatus (resolve, dup-guard,
#                                  create, boot). Skips build/install/verify. Prints
#                                  the resolved facts. For exercising provisioning
#                                  plumbing without an app build.

set -euo pipefail

# --- Exit codes -------------------------------------------------------------
readonly E_USAGE=2
readonly E_DUP=3
readonly E_BUILD=4
readonly E_INSTALL=5
readonly E_NOSTATUS=6
readonly E_TIMEOUT=7
readonly E_DEPS=8
readonly E_ENV=9
readonly E_APPPATH=10

# --- Defaults / constants ---------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly PROJECT="${REPO_ROOT}/KeeForge.xcodeproj"
readonly SCHEME="KeeForge"
readonly STATUS_MARKER="KEEFORGE-AUTOFILL-STORE-STATUS"
readonly STATUS_ARG="-autofill-store-status-log"

readonly DEVICE_NAME="${KEEFORGE_HARNESS_DEVICE_NAME:-KeeForge-AutoFill-Harness}"
readonly DEVICE_TYPE_NAME="${KEEFORGE_HARNESS_DEVICE_TYPE:-iPhone 17 Pro}"
readonly DRY_RUN="${KEEFORGE_HARNESS_DRY_RUN:-0}"

# Verification loop tuning.
readonly INITIAL_PROBE_SECS=30   # grace window to see the marker at all
readonly POLL_INTERVAL=6         # seconds between relaunch/poll cycles
readonly LAUNCH_SETTLE=2         # seconds to let a launch emit its line
readonly LOG_WINDOW=25           # `log show --last <N>s` lookback window

# Flag-driven state.
ERASE=0
APP_PATH=""
TIMEOUT=300

# --- Helpers ----------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { local code="$1"; shift; printf 'error: %s\n' "$*" >&2; exit "$code"; }

usage() {
  # Print the leading comment block (everything after the shebang up to the
  # first non-comment line) as the help text, stripping the "# " prefix.
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

require_deps() {
  command -v xcrun >/dev/null 2>&1 || die "$E_DEPS" "xcrun not found (install Xcode command line tools)."
  command -v jq >/dev/null 2>&1 || die "$E_DEPS" "jq not found (install with 'brew install jq')."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --erase)
        ERASE=1
        shift
        ;;
      --app-path)
        [[ $# -ge 2 ]] || die "$E_USAGE" "--app-path requires a path argument."
        APP_PATH="$2"
        shift 2
        ;;
      --app-path=*)
        APP_PATH="${1#*=}"
        shift
        ;;
      --timeout)
        [[ $# -ge 2 ]] || die "$E_USAGE" "--timeout requires a seconds argument."
        TIMEOUT="$2"
        shift 2
        ;;
      --timeout=*)
        TIMEOUT="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "$E_USAGE" "unknown argument: $1 (see --help)."
        ;;
    esac
  done

  [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "$E_USAGE" "--timeout must be a positive integer (got: ${TIMEOUT})."

  if [[ -n "$APP_PATH" ]]; then
    [[ -d "$APP_PATH" && "$APP_PATH" == *.app ]] || die "$E_APPPATH" "--app-path must point to a .app bundle: ${APP_PATH}"
    [[ -f "$APP_PATH/Info.plist" ]] || die "$E_APPPATH" "no Info.plist inside ${APP_PATH}"
  fi
}

# Newest installed iOS runtime identifier.
resolve_runtime() {
  local id
  id="$(xcrun simctl list runtimes available -j \
    | jq -r '.runtimes
        | map(select(.isAvailable==true and (.identifier|test("SimRuntime.iOS-"))))
        | sort_by(.version | split(".") | map(tonumber))
        | last // empty
        | .identifier')"
  [[ -n "$id" ]] || die "$E_ENV" "no installed iOS simulator runtime found."
  printf '%s' "$id"
}

# Device type identifier for the requested (or fallback) iPhone-class type.
resolve_device_type() {
  local id
  id="$(xcrun simctl list devicetypes -j \
    | jq -r --arg n "$DEVICE_TYPE_NAME" '.devicetypes[] | select(.name==$n) | .identifier' \
    | head -n1)"
  if [[ -z "$id" ]]; then
    warn "device type '${DEVICE_TYPE_NAME}' not available; falling back to newest iPhone-class type."
    id="$(xcrun simctl list devicetypes -j \
      | jq -r '[.devicetypes[] | select(.name|startswith("iPhone "))][0] | .identifier // empty')"
  fi
  [[ -n "$id" ]] || die "$E_ENV" "no iPhone-class simulator device type found."
  printf '%s' "$id"
}

# All UDIDs (across runtimes) for available devices named $DEVICE_NAME.
find_device_udids() {
  xcrun simctl list devices -j \
    | jq -r --arg n "$DEVICE_NAME" '.devices
        | to_entries[] | .value[]
        | select(.name==$n and (.isAvailable!=false))
        | .udid'
}

# Echoes the resolved harness device UDID, creating it if needed.
ensure_device() {
  local runtime_id="$1" devicetype_id="$2"
  local udids count udid
  udids="$(find_device_udids)"
  count="$(printf '%s' "$udids" | grep -c . || true)"

  if [[ "$count" -gt 1 ]]; then
    warn "found ${count} simulators named '${DEVICE_NAME}':"
    printf '%s\n' "$udids" >&2
    die "$E_DUP" "harness device name is ambiguous — delete the extras with 'xcrun simctl delete <udid>' and re-run."
  fi

  if [[ "$count" -eq 1 ]]; then
    udid="$udids"
    info "Reusing existing harness device '${DEVICE_NAME}' (${udid})." >&2
  else
    info "Creating harness device '${DEVICE_NAME}'." >&2
    udid="$(xcrun simctl create "$DEVICE_NAME" "$devicetype_id" "$runtime_id")"
    info "Created ${udid}." >&2
  fi

  printf '%s' "$udid"
}

boot_device() {
  local udid="$1"
  if [[ "$ERASE" -eq 1 ]]; then
    info "Erasing device (this wipes provider enablement)."
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl erase "$udid"
  fi
  info "Booting device."
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  info "Waiting for boot to complete (simctl bootstatus)."
  xcrun simctl bootstatus "$udid"
}

build_app() {
  info "Building Debug KeeForge.app for the generic iOS Simulator destination." >&2
  if ! xcodebuild build \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration Debug \
      -destination 'generic/platform=iOS Simulator' \
      -quiet >&2; then
    die "$E_BUILD" "xcodebuild build failed."
  fi

  local settings build_dir product
  settings="$(xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration Debug \
      -destination 'generic/platform=iOS Simulator' \
      -showBuildSettings 2>/dev/null)"
  build_dir="$(printf '%s\n' "$settings" | grep -m1 ' TARGET_BUILD_DIR = ' | sed 's/^.* = //')"
  product="$(printf '%s\n' "$settings" | grep -m1 ' FULL_PRODUCT_NAME = ' | sed 's/^.* = //')"
  [[ -n "$build_dir" && -n "$product" ]] || die "$E_BUILD" "could not derive built .app path from build settings."

  local app="${build_dir}/${product}"
  [[ -d "$app" ]] || die "$E_BUILD" "built .app not found at ${app}"
  printf '%s' "$app"
}

bundle_id_of() {
  local app="$1" bid
  bid="$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist" 2>/dev/null || true)"
  [[ -n "$bid" ]] || die "$E_INSTALL" "could not read CFBundleIdentifier from ${app}/Info.plist"
  printf '%s' "$bid"
}

print_toggle_instructions() {
  cat >&2 <<EOF

  ------------------------------------------------------------------
  MANUAL STEP (one time per device, until it is erased):
    1. In the Simulator's Settings app (opened for you), go to:
         General  ->  AutoFill & Passwords
    2. Turn ON  "KeeForge"
    3. (Optional) Turn OFF Apple's "Passwords" provider for a cleaner
       signal.
  The script keeps polling and will continue automatically once
  KeeForge reports it is enabled. The screen will briefly flicker
  between KeeForge and Settings while polling — that is expected.
  ------------------------------------------------------------------
EOF
}

# Reads the newest status line from the unified log, or empty string.
read_status_line() {
  local udid="$1"
  xcrun simctl spawn "$udid" log show \
      --style compact \
      --last "${LOG_WINDOW}s" \
      --predicate "eventMessage CONTAINS \"${STATUS_MARKER}\"" 2>/dev/null \
    | grep -oE "${STATUS_MARKER}: enabled=[a-z]+ enumeration=[a-z]+" \
    | tail -n1 || true
}

# Poll until enabled=true, or fail with a distinct code.
verify_enablement() {
  local udid="$1" bundle="$2"
  local start now deadline probe_deadline line marker_seen=0 printed=0

  start="$(date +%s)"
  deadline=$(( start + TIMEOUT ))
  probe_deadline=$(( start + INITIAL_PROBE_SECS ))

  info "Opening Settings to minimize the manual step." >&2
  xcrun simctl launch "$udid" com.apple.Preferences >/dev/null 2>&1 || true

  while :; do
    now="$(date +%s)"
    if (( now >= deadline )); then
      if (( marker_seen )); then
        die "$E_TIMEOUT" "timed out after ${TIMEOUT}s: KeeForge never reported enabled=true — flip the toggle in Settings > General > AutoFill & Passwords > KeeForge."
      fi
      die "$E_NOSTATUS" "installed build never emitted the '${STATUS_MARKER}' line — rebuild and reinstall a Debug build that supports ${STATUS_ARG}."
    fi

    # Relaunch to force a fresh reading, then read the log.
    xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" "$bundle" "$STATUS_ARG" >/dev/null 2>&1 || true
    sleep "$LAUNCH_SETTLE"
    line="$(read_status_line "$udid")"

    if [[ -n "$line" ]]; then
      marker_seen=1
      if [[ "$line" == *"enabled=true"* ]]; then
        info "Verified: ${line}" >&2
        return 0
      fi
      # Seen but disabled — prompt once and keep the user on Settings.
      if (( printed == 0 )); then
        print_toggle_instructions
        printed=1
      fi
      xcrun simctl launch "$udid" com.apple.Preferences >/dev/null 2>&1 || true
    else
      # No marker yet. If the grace window elapsed and we've never seen one,
      # the installed build almost certainly lacks status-log support.
      if (( marker_seen == 0 && now >= probe_deadline )); then
        die "$E_NOSTATUS" "installed build never emitted the '${STATUS_MARKER}' line within ${INITIAL_PROBE_SECS}s — rebuild and reinstall a Debug build that supports ${STATUS_ARG} (or the app failed to launch)."
      fi
    fi

    sleep "$POLL_INTERVAL"
  done
}

main() {
  parse_args "$@"
  require_deps

  local runtime_id devicetype_id udid app bundle
  runtime_id="$(resolve_runtime)"
  devicetype_id="$(resolve_device_type)"

  info "Harness device : ${DEVICE_NAME}"
  info "Device type    : ${devicetype_id}"
  info "Runtime        : ${runtime_id}"

  udid="$(ensure_device "$runtime_id" "$devicetype_id")"
  info "Device UDID    : ${udid}"

  boot_device "$udid"

  if [[ "$DRY_RUN" == "1" ]]; then
    info "KEEFORGE_HARNESS_DRY_RUN=1 set — stopping after boot (no build/install/verify)."
    log "DRY_RUN_OK udid=${udid} runtime=${runtime_id} devicetype=${devicetype_id}"
    exit 0
  fi

  if [[ -n "$APP_PATH" ]]; then
    app="$APP_PATH"
    info "Using provided app: ${app}"
  else
    app="$(build_app)"
    info "Built app: ${app}"
  fi

  bundle="$(bundle_id_of "$app")"
  info "Bundle identifier: ${bundle}"

  info "Installing app on ${udid}."
  if ! xcrun simctl install "$udid" "$app" >/dev/null 2>&1; then
    die "$E_INSTALL" "simctl install failed for ${app}"
  fi

  verify_enablement "$udid" "$bundle"

  log ""
  info "Done. '${DEVICE_NAME}' (${udid}) is provisioned and KeeForge is enabled as the AutoFill provider."
  info "State persists until the device is erased; re-run any time to re-verify."
}

main "$@"
