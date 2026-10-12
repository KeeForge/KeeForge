#!/usr/bin/env bash
# Print where release artifacts live: the main checkout's build/releases, a
# marketing version's directory under it, or one candidate's directory. A linked
# worktree resolves to the main checkout, so every checkout shares one location.
# Prints only; callers create what they need.

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: release_dir.sh [--repo DIR] [{version} | {version}-b{repoBuild} | rc/{version}-b{repoBuild}]
       release_dir.sh --self-test

  (no argument)             <main checkout>/build/releases
  {version}                 <main checkout>/build/releases/{version}
  {version}-b{repoBuild}    <main checkout>/build/releases/{version}/b{repoBuild}
USAGE
}

die() { echo "error: $*" >&2; exit 1; }

run() {
  local repo="$1" name="${2#rc/}" main version_re='[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?'
  main="$(git -C "$repo" worktree list --porcelain | sed -n '1s/^worktree //p')"
  [[ -n "$main" && -d "$main" ]] || die "cannot resolve the main checkout of $repo"
  if [[ -z "$name" ]]; then
    printf '%s\n' "$main/build/releases"
  elif [[ "$name" =~ ^(${version_re})-b([1-9][0-9]*)$ ]]; then
    printf '%s\n' "$main/build/releases/${BASH_REMATCH[1]}/b${BASH_REMATCH[3]}"
  elif [[ "$name" =~ ^${version_re}$ && ! "$name" =~ -b[0-9]*$ ]]; then
    printf '%s\n' "$main/build/releases/$name"
  else
    die "expected {version} or {version}-b{repoBuild}, got: $2"
  fi
}

self_test() {
  local root main linked
  root="$(mktemp -d "${TMPDIR:-/tmp}/keeforge-release-dir.XXXXXX")"
  trap 'rm -rf "${root:-}"' EXIT
  git -C "$root" init -q main
  main="$(cd "$root/main" && pwd -P)"
  git -C "$main" -c user.email=fixture@example.invalid -c user.name=fixture commit -q --allow-empty -m fixture
  git -C "$main" worktree add -q "$root/linked" -b linked
  linked="$root/linked"
  [[ "$(run "$linked" "")" == "$main/build/releases" ]] || die "self-test: a linked worktree did not resolve to the main checkout"
  [[ "$(run "$main" "1.2.3")" == "$main/build/releases/1.2.3" ]] || die "self-test: version directory"
  [[ "$(run "$linked" "1.2.3-b9")" == "$main/build/releases/1.2.3/b9" ]] || die "self-test: candidate directory"
  [[ "$(run "$linked" "rc/1.2.3-b9")" == "$main/build/releases/1.2.3/b9" ]] || die "self-test: RC tag form"
  for bad in "1.2" "1.2.3-b0" "1.2.3-b" "../1.2.3" "1.2.3/b9"; do
    if (run "$main" "$bad") >/dev/null 2>&1; then die "self-test accepted: $bad"; fi
  done
  echo 'self-test: main-checkout resolution, version, candidate, RC tag, and malformed-name checks passed'
}

REPO=""
NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --self-test) self_test; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z "$NAME" ]] || die "only one name is allowed"; NAME="$1"; shift ;;
  esac
done
[[ -n "$REPO" ]] || REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
run "$REPO" "$NAME"
