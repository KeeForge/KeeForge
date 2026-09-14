#!/usr/bin/env bash
# Print the next globally-monotonic KeeForge repository build. This is release
# bookkeeping only; it never modifies project.yml or fetches with --no-fetch.

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: next_repo_build.sh [--no-fetch] [--repo DIR] [--manifest-dir DIR]
       next_repo_build.sh --self-test

Historical target values establish the floor. The current tree must contain
all four product targets with one equal numeric CURRENT_PROJECT_VERSION.
USAGE
}

die() { echo "error: $*" >&2; exit 1; }

NO_FETCH=0
SELF_TEST=0
REPO=""
MANIFEST_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-fetch) NO_FETCH=1; shift ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --manifest-dir) MANIFEST_DIR="${2:-}"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

target_values() {
  awk '
    /^  (KeeForge|KeeForgeAutoFill|KeeForgeMac|KeeForgeMacAutoFill):$/ { target=$1; sub(/:$/, "", target); next }
    /^  [^ ]/ { target="" }
    target && /CURRENT_PROJECT_VERSION:/ {
      value=$0; sub(/^.*CURRENT_PROJECT_VERSION:[[:space:]]*"?/, "", value); sub(/"[[:space:]]*$/, "", value)
      if (value ~ /^[0-9]+$/) print target ":" value
    }
  ' "${1:--}"
}

check_current_project() {
  local file="$1" rows names expected values
  rows="$(target_values "$file")"
  [[ "$(printf '%s\n' "$rows" | sed '/^$/d' | wc -l | tr -d ' ')" == 4 ]] || die "current project.yml must contain all four product targets with numeric builds"
  names="$(printf '%s\n' "$rows" | cut -d: -f1 | sort)"
  expected="$(printf '%s\n' KeeForge KeeForgeAutoFill KeeForgeMac KeeForgeMacAutoFill | sort)"
  [[ "$names" == "$expected" ]] || die "current project.yml target set is incomplete or duplicated"
  values="$(printf '%s\n' "$rows" | cut -d: -f2 | sort -u)"
  [[ "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" == 1 ]] || die "current product targets do not share one CURRENT_PROJECT_VERSION"
  printf '%s\n' "$values"
}

validate_manifest() {
  local manifest="$1" build version tag expected_name
  python3 - "$manifest" <<'PY'
import json, re, sys
p = sys.argv[1]
try:
    data = json.load(open(p, encoding="utf-8"))
except Exception as error:
    raise SystemExit(f"malformed manifest {p}: {error}")
build = data.get("repoBuild")
version = data.get("version")
if not isinstance(build, int) or isinstance(build, bool) or build <= 0:
    raise SystemExit(f"manifest {p} has no positive integer repoBuild")
if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?", version):
    raise SystemExit(f"manifest {p} has invalid version")
if data.get("rcTag") != f"rc/{version}-b{build}":
    raise SystemExit(f"manifest {p} RC tag does not match version/build")
print(build)
PY
}

run() {
  [[ -n "$REPO" ]] || REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  REPO="$(cd "$REPO" && pwd -P)"
  [[ -f "$REPO/project.yml" ]] || die "missing project.yml in $REPO"
  [[ -n "$MANIFEST_DIR" ]] || MANIFEST_DIR="$REPO/scratch/release-manifests"
  if (( ! NO_FETCH )); then
    git -C "$REPO" fetch origin --tags 'refs/heads/release/*:refs/remotes/origin/release/*'
  fi
  local current refs commits history_values manifest_values sha value
  current="$(check_current_project "$REPO/project.yml")"
  refs=(HEAD)
  while IFS= read -r ref; do [[ -n "$ref" ]] && refs+=("$ref"); done < <(git -C "$REPO" for-each-ref --format='%(refname)' refs/heads/release refs/remotes/origin/release refs/tags/rc refs/tags/v)
  commits="$(for ref in "${refs[@]}"; do git -C "$REPO" rev-list "$ref" -- project.yml; done | sort -u)"
  [[ -n "$commits" ]] || die "no reachable project.yml history; cannot establish a build floor"
  history_values=""
  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    while IFS=: read -r _ value; do [[ -n "$value" ]] && history_values+="$value"$'\n'; done < <(git -C "$REPO" show "$sha:project.yml" 2>/dev/null | target_values || true)
  done <<<"$commits"
  [[ -n "$history_values" ]] || die "no usable numeric historical build value; cannot assume zero"
  manifest_values=""
  if [[ -d "$MANIFEST_DIR" ]]; then
    while IFS= read -r manifest; do
      build="$(validate_manifest "$manifest")" || die "invalid release manifest: $manifest"
      expected_name="$(python3 - "$manifest" "$build" <<'PY'
import json, os, sys
d=json.load(open(sys.argv[1]))
print(f"{d['version']}-b{sys.argv[2]}.json")
PY
)"
      [[ "$(basename "$manifest")" == "$expected_name" ]] || die "manifest filename does not match version/build: $manifest"
      manifest_values+="$build"$'\n'
    done < <(find "$MANIFEST_DIR" -type f -name '*.json' -print | sort)
  fi
  local all_values floor
  all_values="$(printf '%s%s%s\n' "$history_values" "$manifest_values" "$current" | sed '/^$/d' | sort -n -u)"
  [[ -n "$all_values" ]] || die "no validated values establish a build floor"
  floor="$(printf '%s\n' "$all_values" | tail -n 1)"
  [[ "$current" =~ ^[0-9]+$ ]] || die "current build is not numeric"
  printf 'validated repo builds: %s\n' "$(printf '%s\n' "$all_values" | tr '\n' ' ' | sed 's/ $//')"
  printf 'current repoBuild: %s\n' "$current"
  printf 'next repoBuild: %s\n' "$((floor + 1))"
}

self_test() {
  local root repo manifests result
  root="$(mktemp -d "${TMPDIR:-/tmp}/keeforge-next-build.XXXXXX")"
  trap 'rm -rf "${root:-}"' EXIT
  repo="$root/repo"; manifests="$repo/scratch/release-manifests"
  mkdir -p "$manifests"; git -C "$root" init -q repo
  git -C "$repo" config user.email fixture@example.invalid; git -C "$repo" config user.name fixture
  cat >"$repo/project.yml" <<'YAML'
targets:
  KeeForge:
    settings:
      base:
        CURRENT_PROJECT_VERSION: "7"
  KeeForgeAutoFill:
    settings:
      base:
        CURRENT_PROJECT_VERSION: "3"
YAML
  git -C "$repo" add project.yml; git -C "$repo" commit -qm legacy
  cat >"$repo/project.yml" <<'YAML'
targets:
  KeeForge:
    settings:
      base:
        CURRENT_PROJECT_VERSION: "12"
  KeeForgeAutoFill:
    settings:
      base:
        CURRENT_PROJECT_VERSION: "12"
  KeeForgeMac:
    settings:
      base:
        CURRENT_PROJECT_VERSION: "12"
  KeeForgeMacAutoFill:
    settings:
      base:
        CURRENT_PROJECT_VERSION: "12"
YAML
  git -C "$repo" add project.yml; git -C "$repo" commit -qm current
  printf '%s\n' '{"version":"1.0.0","repoBuild":14,"rcTag":"rc/1.0.0-b14"}' >"$manifests/1.0.0-b14.json"
  result="$($0 --no-fetch --repo "$repo")"
  grep -Fq 'next repoBuild: 15' <<<"$result" || die "self-test did not honor manifest monotonic floor"
  sed -i '' 's/KeeForgeMacAutoFill:/Other:/' "$repo/project.yml"
  if "$0" --no-fetch --repo "$repo" >/dev/null 2>&1; then die "self-test accepted missing current target"; fi
  sed -i '' 's/Other:/KeeForgeMacAutoFill:/' "$repo/project.yml"
  perl -0pi -e 's/CURRENT_PROJECT_VERSION: "12"/CURRENT_PROJECT_VERSION: "13"/' "$repo/project.yml"
  if "$0" --no-fetch --repo "$repo" >/dev/null 2>&1; then die "self-test accepted unequal current targets"; fi
  perl -0pi -e 's/CURRENT_PROJECT_VERSION: "13"/CURRENT_PROJECT_VERSION: "12"/' "$repo/project.yml"
  printf '%s\n' '{bad json' >"$manifests/1.1.0-b15.json"
  if "$0" --no-fetch --repo "$repo" >/dev/null 2>&1; then die "self-test accepted malformed manifest"; fi
  rm "$manifests/1.1.0-b15.json"
  perl -0pi -e 's/CURRENT_PROJECT_VERSION: "12"/CURRENT_PROJECT_VERSION: "99"/g' "$repo/project.yml"
  result="$($0 --no-fetch --repo "$repo")"
  grep -Fq 'next repoBuild: 100' <<<"$result" || die "self-test did not include an uncommitted current build in the floor"
  echo 'self-test: legacy/missing/unequal/manifest/current-floor checks passed'
}

if (( SELF_TEST )); then self_test; else run; fi
