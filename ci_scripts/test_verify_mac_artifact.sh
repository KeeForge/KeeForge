#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keeforge-host-fixture.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
host="${TMP_DIR}/keeforge-browser-host"
touch "$host"
chmod +x "$host"
die() { echo "error: $*" >&2; exit 1; }
# Load the production functions without running the artifact CLI.
source <(sed -n '/^bundle_hardening() {/,/^codesign --verify --deep/p' "${SCRIPT_DIR}/verify_mac_artifact.sh" | sed '$d')
codesign() {
  if [[ "$*" == *--verify* ]]; then [[ "$CASE" != signature ]]; return; fi
  if [[ "$*" == *--entitlements* ]]; then cat "${TMP_DIR}/fixture.plist"; return; fi
  echo 'TeamIdentifier=FIXTURE'
  [[ "$CASE" == runtime ]] || echo 'flags=0x10000(runtime)'
  return 0
}
passed=0
for CASE in valid missing signature runtime sandbox group extra cs debug malformed; do
  export CASE
  python3 - "${TMP_DIR}/fixture.plist" "$CASE" <<'PY'
import plistlib, sys
case = sys.argv[2]
e = {"com.apple.security.app-sandbox": True, "com.apple.security.application-groups": ["FIXTURE.com.keevault.browser"]}
if case == "sandbox": e["com.apple.security.app-sandbox"] = False
if case == "group": e["com.apple.security.application-groups"].append("group.com.keevault.shared")
if case == "extra": e["unexpected"] = True
if case == "cs": e["com.apple.security.cs.allow-jit"] = True
if case == "debug": e["get-task-allow"] = True
with open(sys.argv[1], "wb") as f:
    f.write(b"bad plist" if case == "malformed" else plistlib.dumps(e))
PY
  target="$host"
  [[ "$CASE" != missing ]] || target="${TMP_DIR}/absent"
  if (verify_browser_host "$target") >"${TMP_DIR}/result" 2>&1; then
    [[ "$CASE" == valid ]] || { echo "FAIL: accepted $CASE" >&2; exit 1; }
  else
    [[ "$CASE" != valid ]] || { cat "${TMP_DIR}/result" >&2; exit 1; }
  fi
  passed=$((passed + 1))
done
echo "browser host artifact fixtures: ${passed} passed"
