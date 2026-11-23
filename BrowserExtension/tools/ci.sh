#!/bin/bash
# Every extension check, in the order CI runs them: Node tests (zero skips), content sync, deterministic build, the
# shipped archive, icons, then real headless Chrome and Firefox against build/chrome and build/firefox.
# Usage: tools/ci.sh [stage ...]. Logs and screenshots go to $CI_OUT (default build/ci). Exits nonzero if any stage fails.
set -uo pipefail
set -m # each stage gets its own process group, so a timeout also stops its browsers and mock hosts
extension_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$extension_dir"
unset NODE_USE_SYSTEM_CA
out="${CI_OUT:-$extension_dir/build/ci}"
rm -rf "$out" && mkdir -p "$out"
failed=() summary=()

stage() { # name timeout-seconds command...
  local name="$1" limit="$2"; shift 2
  [ -n "$only" ] && [[ " $only " != *" $name "* ]] && return
  local log="$out/$name.log" start=$SECONDS
  echo "::group::$name"
  "$@" > "$log" 2>&1 &
  local pid=$!
  ( sleep "$limit"; echo "TIMEOUT after ${limit}s" >> "$log"; kill -TERM -- -"$pid" 2>/dev/null; sleep 5; kill -KILL -- -"$pid" 2>/dev/null ) &
  local watchdog=$!
  wait "$pid"; local status=$?
  kill -- -"$watchdog" 2>/dev/null; kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  cat "$log"
  echo "::endgroup::"
  local result="PASS"
  [ "$status" -eq 0 ] || { result="FAIL"; failed+=("$name"); }
  summary+=("$(printf '%s  %-14s %4ss  %s' "$result" "$name" "$((SECONDS - start))" "$(tail -n 1 "$log" | cut -c1-110)")")
  echo "$result $name (exit $status, $((SECONDS - start))s)"
}

node_tests() {
  node --test --test-reporter=tap > "$out/node-tests.tap"; local status=$?
  grep -E '^not ok|^# (tests|pass|fail|cancelled|skipped|todo) ' "$out/node-tests.tap"
  local count; count() { awk -v k="# $1" 'index($0, k " ") == 1 { print $3 }' "$out/node-tests.tap"; }
  local tests pass; tests=$(count tests) pass=$(count pass)
  [ "$status" -eq 0 ] || return 1
  [ -n "$tests" ] && [ "$tests" -gt 0 ] || { echo "no tests ran"; return 1; }
  for key in fail cancelled skipped todo; do [ "$(count "$key")" = 0 ] || { echo "$key is not zero"; return 1; }; done
  [ "$pass" = "$tests" ] || { echo "$pass of $tests passed"; return 1; }
  echo "$tests tests passed, none skipped"
}

deterministic_build() {
  local hash; hash() { node -e 'const c=require("crypto"),f=require("fs");for(const p of process.argv.slice(1))console.log(c.createHash("sha256").update(f.readFileSync(p)).digest("hex"),p.split("/").pop())' build/chrome.zip build/firefox.zip; }
  tools/build.sh || return 1; local first; first=$(hash)
  sleep 2 # a timestamp leak would differ (zip times have two-second resolution)
  tools/build.sh || return 1; local second; second=$(hash)
  echo "$second"
  [ "$first" = "$second" ] || { echo "archives differ between two builds:"; echo "$first"; return 1; }
  echo "two builds produced identical archives"
}

versions() {
  node --version
  # Global WebSocket (22) and recursive readdir with parentPath are used by the tools.
  node -e 'process.exit(+process.versions.node.split(".")[0] >= 22 ? 0 : 1)' || { echo "Node 22 or newer is required"; return 1; }
  local chrome firefox
  chrome=$(node -e 'import("./tools/chrome-cdp.mjs").then(b => console.log(b.chromePath()))') || return 1
  firefox=$(node -e 'import("./tools/chrome-cdp.mjs").then(b => console.log(b.firefoxPath()))') || return 1
  echo "$chrome"; "$chrome" --version || return 1
  echo "$firefox"; "$firefox" --version || return 1
}

only="${*:-}"
stage versions        30 versions
stage node-tests     120 node_tests
stage sync-content    30 node tools/sync-content.mjs --check
stage build           60 deterministic_build
stage check-build     30 node tools/check-build.mjs
stage icons           60 node tools/render-icons.mjs --check
stage fill-chrome    120 env EXTENSION_DIR=build/chrome node tools/browser-check.mjs
stage inline-chrome  300 env EXTENSION_DIR=build/chrome SHOTS="$out/inline-shots" node tools/inline-browser-check.mjs
stage ui-chrome      300 env EXTENSION_DIR=build/chrome node tools/screenshot-ui.mjs "$out/ui-shots"
stage firefox        120 env EXTENSION_DIR=build/firefox node tools/firefox-check.mjs

echo
printf '%s\n' "${summary[@]}" | tee "$out/summary.txt"
if [ "${#failed[@]}" -gt 0 ]; then echo "FAILED: ${failed[*]} (logs in $out)"; exit 1; fi
echo "All browser-extension checks passed (logs in $out)"
