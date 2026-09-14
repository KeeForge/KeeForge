#!/usr/bin/env bash
#
# Archive, sign, notarize and staple the direct-download (Developer ID) macOS
# build, then emit the zip that the Sparkle appcast points at.
#
# The Mac App Store build does not go through here — it is archived and uploaded
# the same way the iOS app is (Xcode Cloud / Organizer). This script is only the
# second channel.
#
# Prerequisites, none of which live in the repo:
#   * A "Developer ID Application" certificate in the login keychain.
#   * Developer ID provisioning profiles for com.keevault.app and
#     com.keevault.app.autofill. Xcode creates both on demand — the archive and
#     export below pass -allowProvisioningUpdates — so no portal visit is
#     needed. Making them by hand still works if you prefer to pin the
#     entitlements a profile authorizes.
#   * A notarytool credential profile stored in the keychain:
#       xcrun notarytool store-credentials keeforge-notary \
#         --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
#   * SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY set (see BuildConfig.local.xcconfig);
#     the matching EdDSA private key stays in the login keychain, never in the
#     repo and never in CI logs.
#
# Usage: ci_scripts/build_mac_direct.sh [--preflight] [--rc-tag TAG] [output-dir]
#
# The build writes direct-artifact.json beside the zip. It is a non-secret
# handoff record consumed by release_direct_artifact.sh after App Review.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
BUILD_ROOT="${REPO_ROOT}/build"

PREFLIGHT=0
RC_TAG=""
REQUESTED_OUT_DIR=""
while (( $# > 0 )); do
  case "$1" in
    --preflight) PREFLIGHT=1; shift ;;
    --rc-tag) RC_TAG="${2:-}"; shift 2 ;;
    -h|--help) echo "usage: ${BASH_SOURCE[0]} [--preflight] [--rc-tag TAG] [output-dir]"; exit 0 ;;
    -*) echo "error: unknown option $1" >&2; exit 2 ;;
    *) [[ -z "$REQUESTED_OUT_DIR" ]] || { echo "error: only one output directory is allowed" >&2; exit 2; }; REQUESTED_OUT_DIR="$1"; shift ;;
  esac
done

candidate_identity() {
  awk '
    /^  (KeeForge|KeeForgeAutoFill|KeeForgeMac|KeeForgeMacAutoFill):$/ { target=$1; sub(/:$/, "", target); next }
    /^  [^ ]/ { target="" }
    target && /MARKETING_VERSION:/ { value=$0; sub(/^.*MARKETING_VERSION:[[:space:]]*"?/, "", value); sub(/"[[:space:]]*$/, "", value); version[target]=value }
    target && /CURRENT_PROJECT_VERSION:/ { value=$0; sub(/^.*CURRENT_PROJECT_VERSION:[[:space:]]*"?/, "", value); sub(/"[[:space:]]*$/, "", value); build[target]=value }
    END { for (name in build) print name ":" version[name] ":" build[name] }
  ' "${REPO_ROOT}/project.yml"
}

resolve_candidate_identity() {
  local rows versions builds version build expected_tag tagged_sha head_sha
  rows="$(candidate_identity)"
  [[ "$(printf '%s\n' "$rows" | sed '/^$/d' | wc -l | tr -d ' ')" == 4 ]] || { echo "error: project.yml must define all four release targets" >&2; return 1; }
  versions="$(printf '%s\n' "$rows" | cut -d: -f2 | sort -u)"
  builds="$(printf '%s\n' "$rows" | cut -d: -f3 | sort -u)"
  [[ "$(printf '%s\n' "$versions" | wc -l | tr -d ' ')" == 1 && "$(printf '%s\n' "$builds" | wc -l | tr -d ' ')" == 1 ]] || { echo "error: release targets must share version and repo build" >&2; return 1; }
  version="$versions"; build="$builds"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ && "$build" =~ ^[1-9][0-9]*$ ]] || { echo "error: invalid release version/build in project.yml" >&2; return 1; }
  expected_tag="rc/${version}-b${build}"
  [[ -z "$RC_TAG" || "$RC_TAG" == "$expected_tag" ]] || { echo "error: --rc-tag must match project.yml identity ${expected_tag}" >&2; return 1; }
  RC_TAG="$expected_tag"
  tagged_sha="$(git -C "$REPO_ROOT" rev-parse "${RC_TAG}^{commit}" 2>/dev/null || true)"
  head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  [[ -n "$tagged_sha" && "$tagged_sha" == "$head_sha" ]] || { echo "error: clean source must be checked out at ${RC_TAG}" >&2; return 1; }
  RELEASE_VERSION="$version"; RELEASE_BUILD="$build"
}

reject_output_dir() {
  local build_root="${2:-${BUILD_ROOT}}"
  echo "error: refusing unsafe direct-build output directory: $1" >&2
  echo "The output must be an absolute, safe-named directory directly under ${build_root}." >&2
  return 1
}

validate_output_dir() {
  local candidate="$1"
  local build_root="${2:-${BUILD_ROOT}}"
  local base
  local build_real
  local build_parent_real
  local candidate_real

  [[ "${candidate}" == /* ]] || { reject_output_dir "${candidate} (relative path)"; return 1; }
  [[ "${candidate}" != "${build_root}" ]] || { reject_output_dir "${candidate} (build root itself)"; return 1; }
  [[ "${candidate}" == "${build_root}/"* ]] || { reject_output_dir "${candidate} (unexpected parent)"; return 1; }

  base="${candidate#"${build_root}/"}"
  [[ -n "${base}" && "${base}" != */* && "${base}" != "." && "${base}" != ".." ]] \
    || { reject_output_dir "${candidate} (not a direct child)"; return 1; }
  [[ "${base}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
    || { reject_output_dir "${candidate} (unsafe basename)"; return 1; }
  [[ "${candidate}" == "${build_root}/${base}" ]] \
    || { reject_output_dir "${candidate} (non-canonical path)"; return 1; }

  [[ ! -L "${build_root}" ]] || { reject_output_dir "${candidate} (build root is a symlink)"; return 1; }
  [[ -d "${build_root}" ]] || { reject_output_dir "${candidate} (missing build directory)"; return 1; }
  build_real="$(cd -P -- "${build_root}" && pwd -P)" \
    || { reject_output_dir "${candidate} (cannot resolve build directory)"; return 1; }
  build_parent_real="$(cd -P -- "$(dirname "${build_root}")" && pwd -P)" \
    || { reject_output_dir "${candidate} (cannot resolve build parent)"; return 1; }
  [[ "${build_real}" == "${build_parent_real}/$(basename "${build_root}")" ]] \
    || { reject_output_dir "${candidate} (build directory escapes the repository)"; return 1; }

  if [[ -L "${candidate}" ]]; then
    reject_output_dir "${candidate} (output directory is a symlink)"
    return 1
  fi
  if [[ -e "${candidate}" && ! -d "${candidate}" ]]; then
    reject_output_dir "${candidate} (existing output is not a directory)"
    return 1
  fi
  if [[ -d "${candidate}" ]]; then
    candidate_real="$(cd -P -- "${candidate}" && pwd -P)" \
      || { reject_output_dir "${candidate} (cannot resolve output directory)"; return 1; }
    [[ "${candidate_real}" == "${build_real}/${base}" ]] \
      || { reject_output_dir "${candidate} (output directory escapes the repository)"; return 1; }
  fi
}

reject_completed_output() {
  local candidate="$1"
  local existing_zip
  [[ ! -e "${candidate}/direct-artifact.json" ]] || {
    echo "error: ${candidate} already contains direct-artifact.json; choose a fresh candidate output directory" >&2
    return 1
  }
  [[ ! -e "${candidate}/notarization.json" ]] || {
    echo "error: ${candidate} already contains notarization.json; preserve its accepted artifact and finalize metadata manually" >&2
    return 1
  }
  existing_zip="$(find "${candidate}" -maxdepth 1 -type f -name 'KeeForge-*-b*.zip' -print -quit 2>/dev/null || true)"
  [[ -z "${existing_zip}" ]] || {
    echo "error: ${candidate} already contains a release ZIP; do not rearchive accepted bytes" >&2
    return 1
  }
}

require_clean_source_worktree() {
  local repo="$1"
  local status

  status="$(git -C "${repo}" status --porcelain=v1 --untracked-files=all)" \
    || { echo "error: could not inspect source worktree ${repo}" >&2; return 1; }
  if [[ -n "${status}" ]]; then
    echo "error: source worktree is not clean; refusing to remove output or regenerate the project." >&2
    echo "Tracked changes and untracked non-ignored files could enter this globs-based release." >&2
    echo "Ignored build/ and scratch/ outputs are intentionally omitted and remain allowed." >&2
    printf '%s\n' "${status}" >&2
    return 1
  fi
}

validate_temp_dir() {
  local temp_dir="$1"
  local temp_real

  [[ "${temp_dir}" == /* && -d "${temp_dir}" && ! -L "${temp_dir}" ]] \
    || { echo "error: invalid temporary state directory ${temp_dir}" >&2; return 1; }
  temp_real="$(cd -P -- "${temp_dir}" && pwd -P)" \
    || { echo "error: cannot resolve temporary state directory ${temp_dir}" >&2; return 1; }
  [[ "${temp_real}" == "${temp_dir}" ]] \
    || { echo "error: temporary state directory resolves unexpectedly: ${temp_dir}" >&2; return 1; }
  [[ "${temp_real}" != "/" && "${temp_real}" != "${HOME:-}" && "${temp_real}" != "${REPO_ROOT}" ]] \
    || { echo "error: refusing unsafe temporary state directory ${temp_dir}" >&2; return 1; }
}

save_resolved_state() {
  local resolved_path="$1"
  local state_dir="$2"

  if [[ -L "${resolved_path}" ]]; then
    echo "error: refusing to save symlinked ${resolved_path}" >&2
    return 1
  fi
  if [[ -e "${resolved_path}" && ! -f "${resolved_path}" ]]; then
    echo "error: expected ${resolved_path} to be a regular file or absent" >&2
    return 1
  fi
  if [[ -f "${resolved_path}" ]]; then
    cp -p -- "${resolved_path}" "${state_dir}/Package.resolved"
    : >"${state_dir}/present"
  fi
}

restore_resolved_state() {
  local resolved_path="$1"
  local state_dir="$2"

  if [[ -f "${state_dir}/present" ]]; then
    if [[ -L "${resolved_path}" || ( -e "${resolved_path}" && ! -f "${resolved_path}" ) ]]; then
      echo "error: cannot restore ${resolved_path}; generated path is not a regular file" >&2
      return 1
    fi
    cp -p -- "${state_dir}/Package.resolved" "${resolved_path}"
  elif [[ -e "${resolved_path}" || -L "${resolved_path}" ]]; then
    rm -f -- "${resolved_path}"
  fi
}

run_preflight() {
  local test_root
  local test_repo
  local test_resolved
  local state_dir
  local original_bytes='Package.resolved\nbyte-exact\n'
  local rejected
  local saved_repo_root saved_rc_tag
  local stub_bin control_log
  local synthetic_attrs synthetic_length

  test_root="$(mktemp -d "${TMPDIR:-/tmp}/keeforge-direct-preflight.XXXXXX")"
  test_root="$(cd -P -- "${test_root}" && pwd -P)"
  validate_temp_dir "${test_root}"
  test_repo="${test_root}/repo"
  mkdir -p -- "${test_repo}/build"
  git -C "${test_repo}" init -q
  git -C "${test_repo}" config user.email preflight@example.invalid
  git -C "${test_repo}" config user.name preflight
  : >"${test_repo}/tracked"
  printf 'build/\nscratch/\nci_scripts/\nConfigs/\n' >"${test_repo}/.gitignore"
  git -C "${test_repo}" add .
  git -C "${test_repo}" commit -q -m preflight
  require_clean_source_worktree "${test_repo}"
  printf 'tracked change\n' >"${test_repo}/tracked"
  if require_clean_source_worktree "${test_repo}" >/dev/null 2>&1; then
    echo "error: preflight failed to reject a tracked source change" >&2
    return 1
  fi
  : >"${test_repo}/tracked"
  : >"${test_repo}/untracked-source.swift"
  if require_clean_source_worktree "${test_repo}" >/dev/null 2>&1; then
    echo "error: preflight failed to reject an untracked source file" >&2
    return 1
  fi
  rm -f -- "${test_repo}/untracked-source.swift"
  : >"${test_repo}/build/ignored-output"
  mkdir -p -- "${test_repo}/scratch"
  : >"${test_repo}/scratch/ignored-output"
  require_clean_source_worktree "${test_repo}"
  validate_output_dir "${test_repo}/build/mac-direct" "${test_repo}/build"
  validate_output_dir "${test_repo}/build/allowed-output" "${test_repo}/build"
  mkdir -p "${test_repo}/build/completed-output"
  : >"${test_repo}/build/completed-output/direct-artifact.json"
  if reject_completed_output "${test_repo}/build/completed-output" >/dev/null 2>&1; then
    echo "error: preflight accepted completed direct artifact output" >&2
    return 1
  fi
  rm "${test_repo}/build/completed-output/direct-artifact.json"
  : >"${test_repo}/build/completed-output/notarization.json"
  if reject_completed_output "${test_repo}/build/completed-output" >/dev/null 2>&1; then
    echo "error: preflight accepted interrupted notarization output" >&2
    return 1
  fi
  rm "${test_repo}/build/completed-output/notarization.json"
  : >"${test_repo}/build/completed-output/KeeForge-1.2.3-b9.zip"
  if reject_completed_output "${test_repo}/build/completed-output" >/dev/null 2>&1; then
    echo "error: preflight accepted an existing release ZIP" >&2
    return 1
  fi
  cat >"${test_repo}/project.yml" <<'YAML'
targets:
  KeeForge:
    settings:
      base:
        MARKETING_VERSION: "1.2.3"
        CURRENT_PROJECT_VERSION: "9"
  KeeForgeAutoFill:
    settings:
      base:
        MARKETING_VERSION: "1.2.3"
        CURRENT_PROJECT_VERSION: "9"
  KeeForgeMac:
    settings:
      base:
        MARKETING_VERSION: "1.2.3"
        CURRENT_PROJECT_VERSION: "9"
  KeeForgeMacAutoFill:
    settings:
      base:
        MARKETING_VERSION: "1.2.3"
        CURRENT_PROJECT_VERSION: "9"
YAML
  git -C "${test_repo}" add project.yml
  git -C "${test_repo}" commit -q -m candidate
  git -C "${test_repo}" tag rc/1.2.3-b9
  saved_repo_root="${REPO_ROOT}"; saved_rc_tag="${RC_TAG}"
  REPO_ROOT="${test_repo}"; RC_TAG=""
  resolve_candidate_identity
  [[ "${RC_TAG}" == "rc/1.2.3-b9" ]] || { echo "error: preflight did not derive the RC tag" >&2; return 1; }
  : >"${test_repo}/after-tag"
  git -C "${test_repo}" add after-tag
  git -C "${test_repo}" commit -q -m after-tag
  if resolve_candidate_identity >/dev/null 2>&1; then
    echo "error: preflight accepted a source checkout after its RC tag" >&2
    return 1
  fi
  REPO_ROOT="${saved_repo_root}"; RC_TAG="${saved_rc_tag}"
  # Exercise the normal entry path in a clean disposable repo. xcrun is a
  # deliberate local stub: reaching its expected credential refusal proves the
  # candidate output was resolved before the first external preflight.
  mkdir -p "${test_repo}/ci_scripts" "${test_repo}/Configs"
  git -C "${test_repo}" checkout -q rc/1.2.3-b9
  cp "${BASH_SOURCE[0]}" "${test_repo}/ci_scripts/build_mac_direct.sh"
  : >"${test_repo}/Configs/ExportOptions-DeveloperID.plist"
  stub_bin="${test_root}/stub-bin"; mkdir "${stub_bin}"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"${stub_bin}/xcrun"
  chmod +x "${stub_bin}/xcrun"
  control_log="${test_root}/normal-control-flow.log"
  if PATH="${stub_bin}:${PATH}" "${test_repo}/ci_scripts/build_mac_direct.sh" >"${control_log}" 2>&1; then
    echo "error: preflight control-flow fixture unexpectedly reached a build" >&2
    return 1
  fi
  grep -Fq "no notarytool credential profile" "${control_log}" \
    || { echo "error: preflight control-flow fixture did not reach the stubbed notary preflight" >&2; return 1; }
  ! grep -Eq 'unbound variable|OUT_DIR:.*unbound' "${control_log}" \
    || { echo "error: preflight control-flow fixture used OUT_DIR before assignment" >&2; return 1; }
  synthetic_attrs='sparkle:edSignature="synthetic-signature" length="9791801"'
  synthetic_length="$(sed -n 's/.*[[:space:]]\(sparkle:\)\{0,1\}length="\([^"]*\)".*/\2/p' <<<"${synthetic_attrs}")"
  [[ "${synthetic_length}" == 9791801 ]] \
    || { echo "error: preflight failed to parse portable Sparkle length attributes" >&2; return 1; }
  ln -s "${test_root}/outside" "${test_repo}/build/escaped-link"

  for rejected in \
    "build/relative" \
    "${test_repo}/build" \
    "${test_repo}/build/../escape" \
    "${test_repo}/build/allowed-output/nested" \
    "${test_repo}/outside" \
    "/" \
    "${HOME:-/Users}" \
    "/Users" \
    "${test_repo}" \
    "${test_repo}/build/escaped-link"; do
    if validate_output_dir "${rejected}" "${test_repo}/build" >/dev/null 2>&1; then
      echo "error: preflight accepted rejected output path ${rejected}" >&2
      return 1
    fi
  done

  test_resolved="${test_repo}/Package.resolved"
  state_dir="${test_root}/state-present"
  mkdir -- "${state_dir}"
  printf '%b' "${original_bytes}" >"${test_resolved}"
  save_resolved_state "${test_resolved}" "${state_dir}"
  printf 'changed\n' >"${test_resolved}"
  restore_resolved_state "${test_resolved}" "${state_dir}"
  cmp -s "${test_resolved}" "${state_dir}/Package.resolved" \
    || { echo "error: preflight failed byte-exact Package.resolved restoration" >&2; return 1; }

  state_dir="${test_root}/state-absent"
  mkdir -- "${state_dir}"
  rm -f -- "${test_resolved}"
  save_resolved_state "${test_resolved}" "${state_dir}"
  printf 'generated\n' >"${test_resolved}"
  restore_resolved_state "${test_resolved}" "${state_dir}"
  [[ ! -e "${test_resolved}" && ! -L "${test_resolved}" ]] \
    || { echo "error: preflight failed to restore prior Package.resolved absence" >&2; return 1; }

  rm -rf -- "${test_root}"
  echo "preflight: output-path, interrupted-output, RC identity, clean-worktree, and Package.resolved restore checks passed"
}

if (( PREFLIGHT )); then
  run_preflight
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required before starting the archive/notarization flow" >&2
  exit 1
fi

cd "${REPO_ROOT}"

# The project uses folder globs. A dirty checkout could therefore include an
# untracked source file in the archive even though it is not part of a commit.
# build/ and scratch/ are ignored output locations and are intentionally fine.
require_clean_source_worktree "${REPO_ROOT}"
resolve_candidate_identity
OUT_DIR="${REQUESTED_OUT_DIR:-${BUILD_ROOT}/mac-direct-${RELEASE_VERSION}-b${RELEASE_BUILD}}"
if [[ -L "${BUILD_ROOT}" ]]; then
  reject_output_dir "${OUT_DIR} (build root is a symlink)"
fi
if [[ ! -d "${BUILD_ROOT}" ]]; then
  mkdir -p -- "${BUILD_ROOT}"
fi
validate_output_dir "${OUT_DIR}"
reject_completed_output "${OUT_DIR}"

NOTARY_PROFILE="${KEEFORGE_NOTARY_PROFILE:-keeforge-notary}"
SCHEME="KeeForgeMac"

# A dedicated derived-data path, because this build is the same target and the
# same product name as the App Store build, only regenerated from a different
# spec. Sharing derived data would leave a Sparkle-linked KeeForge.app sitting
# where the App Store build — and the app KeeForgeMacTests hosts in — is
# expected.
DERIVED_DATA="${OUT_DIR}/DerivedData"
ARCHIVE_PATH="${OUT_DIR}/KeeForge.xcarchive"
EXPORT_PATH="${OUT_DIR}/export"
EXPORT_OPTIONS="${REPO_ROOT}/Configs/ExportOptions-DeveloperID.plist"

if [[ ! -f "${EXPORT_OPTIONS}" ]]; then
  echo "error: missing ${EXPORT_OPTIONS}" >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  echo "error: no notarytool credential profile named '${NOTARY_PROFILE}'." >&2
  echo "Create one with: xcrun notarytool store-credentials ${NOTARY_PROFILE} \\" >&2
  echo "  --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>" >&2
  exit 1
fi

# Save the exact Package.resolved bytes before either spec can cause SwiftPM to
# rewrite them. This state directory is validated before it is ever removed.
RESOLVED_FILE="KeeForge.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
RESOLVED_PATH="${REPO_ROOT}/${RESOLVED_FILE}"
PROJECT_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keeforge-direct-project.XXXXXX")"
PROJECT_STATE_DIR="$(cd -P -- "${PROJECT_STATE_DIR}" && pwd -P)"
validate_temp_dir "${PROJECT_STATE_DIR}"
save_resolved_state "${RESOLVED_PATH}" "${PROJECT_STATE_DIR}"

restore_appstore_project() {
  local original_status="$?"
  local restore_status=0

  trap - EXIT
  echo "==> Restoring the App Store project spec"
  if ! (cd "${REPO_ROOT}" && xcodegen generate >/dev/null); then
    echo "error: failed to restore the App Store project spec" >&2
    restore_status=1
  fi
  if ! restore_resolved_state "${RESOLVED_PATH}" "${PROJECT_STATE_DIR}"; then
    echo "error: failed to restore the pre-run Package.resolved state" >&2
    restore_status=1
  fi
  if ! require_clean_source_worktree "${REPO_ROOT}"; then
    echo "error: App Store project restoration left the source worktree dirty" >&2
    restore_status=1
  fi
  if ! rm -rf -- "${PROJECT_STATE_DIR}"; then
    echo "error: failed to remove validated temporary state directory ${PROJECT_STATE_DIR}" >&2
    restore_status=1
  fi
  if (( restore_status != 0 )); then
    echo "error: direct-build cleanup did not fully restore the App Store project" >&2
    if (( original_status == 0 )); then
      original_status=1
    fi
  fi
  exit "${original_status}"
}
trap restore_appstore_project EXIT

mkdir -p -- "${OUT_DIR}"

# The overlay spec is what makes this the direct-download channel: it adds
# Sparkle and defines KEEFORGE_DIRECT_DOWNLOAD. Plain `xcodegen generate` yields
# the App Store build, so regenerate afterwards before doing anything else.
echo "==> Generating project from the direct-download spec"
xcodegen generate --spec project-direct.yml

echo "==> Archiving ${SCHEME}"
xcodebuild archive \
  -project KeeForge.xcodeproj \
  -scheme "${SCHEME}" \
  -destination 'generic/platform=macOS' \
  -archivePath "${ARCHIVE_PATH}" \
  -derivedDataPath "${DERIVED_DATA}" \
  -allowProvisioningUpdates

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -allowProvisioningUpdates

APP_PATH="${EXPORT_PATH}/KeeForge.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: expected ${APP_PATH} after export" >&2
  exit 1
fi

# The hardening posture is a release invariant, not a preference: no
# get-task-allow, and no com.apple.security.cs.* exceptions. Sparkle 2 needs
# none — Xcode signs its XPC services with the team id and library validation
# permits a same-team load. If an update fails, the signing is wrong; do not
# "fix" it by adding an exception here.
#
# Checked on the app *and* on every nested bundle it embeds. The AutoFill
# extension and Sparkle's XPC services are separately signed with their own
# entitlements, so an exception added to one of them would never appear in the
# app's own and would otherwise ship unnoticed.
check_hardening() {
  local bundle="$1"
  local entitlements
  entitlements="$(codesign -d --entitlements - --xml "${bundle}" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)"

  if grep -q "com.apple.security.cs." <<<"${entitlements}"; then
    echo "error: ${bundle##*/} carries a com.apple.security.cs.* exception:" >&2
    grep -o "com.apple.security.cs.[a-z.-]*" <<<"${entitlements}" | sort -u >&2
    return 1
  fi
  if grep -q "get-task-allow" <<<"${entitlements}"; then
    echo "error: ${bundle##*/} carries get-task-allow (debug signing)" >&2
    return 1
  fi
  echo "    ${bundle##*/}: no exceptions"
}

echo "==> Checking entitlements"
APP_ENTITLEMENTS="$(codesign -d --entitlements - --xml "${APP_PATH}" 2>/dev/null | plutil -convert xml1 -o - -)"
if ! grep -q "com.apple.security.app-sandbox" <<<"${APP_ENTITLEMENTS}"; then
  echo "error: build is not sandboxed; both channels must stay sandboxed" >&2
  exit 1
fi

check_hardening "${APP_PATH}"
while IFS= read -r NESTED; do
  check_hardening "${NESTED}"
done < <(find "${APP_PATH}/Contents" \
  \( -name "*.appex" -o -name "*.xpc" -o -name "*.app" \) -print)

# The AutoFill extension must stay sandboxed in its own right: it is the process
# that holds decrypted vault contents while filling.
APPEX="$(find "${APP_PATH}/Contents" -name "*.appex" -print -quit)"
if [[ -n "${APPEX}" ]]; then
  if ! codesign -d --entitlements - --xml "${APPEX}" 2>/dev/null \
    | plutil -convert xml1 -o - - \
    | grep -q "com.apple.security.app-sandbox"; then
    echo "error: ${APPEX##*/} is not sandboxed" >&2
    exit 1
  fi
fi
echo "    hardened runtime + sandbox, no exceptions"

# An update channel is only as good as the two values that authenticate it. An
# empty SUPublicEDKey makes Sparkle refuse every update (fail-closed, but the
# channel is then dead), and a plaintext feed hands an on-path attacker the
# update metadata. Both are build-time settings, so catch them here rather than
# after the appcast is live.
echo "==> Checking the Sparkle update channel"
BUILT_FEED_URL="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)"
BUILT_ED_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "${BUILT_ED_KEY}" ]]; then
  echo "error: SUPublicEDKey is empty; a direct build with no update key cannot ever update." >&2
  echo "Set SPARKLE_PUBLIC_ED_KEY in BuildConfig.local.xcconfig." >&2
  exit 1
fi
if [[ "${BUILT_FEED_URL}" != https://* ]]; then
  echo "error: SUFeedURL must be an https:// URL, got '${BUILT_FEED_URL}'" >&2
  exit 1
fi
echo "    appcast ${BUILT_FEED_URL}, update key present"

ZIP_PATH="${OUT_DIR}/.notarization-payload.zip"
echo "==> Zipping for notarization"
# --sequesterRsrc keeps extended attributes in a __MACOSX sidecar instead of
# inline AppleDouble entries. See the re-zip below for why that matters.
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "==> Notarizing (this waits for Apple)"
NOTARY_JSON="${OUT_DIR}/notarization.json"
xcrun notarytool submit "${ZIP_PATH}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait \
  --output-format json >"${NOTARY_JSON}"
NOTARIZATION_ID="$(jq -er '.id // .submissionId' "${NOTARY_JSON}")"
NOTARIZATION_STATUS="$(jq -er '.status // empty' "${NOTARY_JSON}")"
if [[ "${NOTARIZATION_STATUS}" != "Accepted" ]]; then
  echo "error: notarization status is '${NOTARIZATION_STATUS}', expected Accepted" >&2
  exit 1
fi

echo "==> Stapling"
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "${APP_PATH}"

# Re-zip after stapling: the ticket is stapled into the .app, and the zip the
# appcast serves must contain the stapled copy so a first launch offline still
# passes Gatekeeper.
#
# --sequesterRsrc is not cosmetic. Without it ditto writes each file's extended
# attributes as an inline AppleDouble "._name" entry. Apple's own extractor
# (Finder, Archive Utility, ditto -x -k) consumes those entries, but plain
# `unzip` and most third-party unarchivers materialize them as real files
# *inside* the bundle -- 201 of them here, including one in the root of
# Sparkle.framework. Every one is unsealed content the signature does not cover,
# so Gatekeeper rejects the app the user actually downloaded with "unsealed
# contents present in the root directory of an embedded framework" while the
# same zip passes on the machine that built it. The only attribute in this
# bundle is com.apple.provenance, which nothing signed depends on.
rm -f "${ZIP_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

# Prove that claim about the downloaded app rather than trusting the flag: this
# is the artifact a user unpacks, so unpack it the least forgiving way and let
# Gatekeeper judge the result. spctl on the exported .app cannot catch this --
# the damage only exists after a zip round trip.
echo "==> Verifying the zip a user actually downloads"
ROUNDTRIP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keeforge-direct-roundtrip.XXXXXX")"
if ! unzip -qq "${ZIP_PATH}" -d "${ROUNDTRIP_DIR}"; then
  rm -rf -- "${ROUNDTRIP_DIR}"
  echo "error: the release zip could not be extracted with plain unzip" >&2
  exit 1
fi
ROUNDTRIP_STRAYS="$(find "${ROUNDTRIP_DIR}/KeeForge.app" -name '._*' 2>/dev/null | wc -l | tr -d ' ')"
ROUNDTRIP_ASSESS="$(spctl --assess --type execute --verbose=4 "${ROUNDTRIP_DIR}/KeeForge.app" 2>&1 || true)"
ROUNDTRIP_STAPLE="$(xcrun stapler validate "${ROUNDTRIP_DIR}/KeeForge.app" 2>&1 || true)"
rm -rf -- "${ROUNDTRIP_DIR}"
if [[ "${ROUNDTRIP_STRAYS}" != "0" ]]; then
  echo "error: extracting the release zip leaves ${ROUNDTRIP_STRAYS} AppleDouble file(s) inside the bundle" >&2
  exit 1
fi
if ! grep -q "accepted" <<<"${ROUNDTRIP_ASSESS}"; then
  echo "error: Gatekeeper rejects the app extracted from the release zip:" >&2
  printf '%s\n' "${ROUNDTRIP_ASSESS}" >&2
  exit 1
fi
if ! grep -q "The validate action worked" <<<"${ROUNDTRIP_STAPLE}"; then
  echo "error: the stapled ticket did not survive the release zip round trip:" >&2
  printf '%s\n' "${ROUNDTRIP_STAPLE}" >&2
  exit 1
fi
echo "    plain unzip: no AppleDouble strays, Gatekeeper accepted, ticket stapled"

# sign_update ships inside the Sparkle SPM artifact bundle, which the archive
# above already resolved into this run's derived data. Locating it there keeps
# the appcast signature a step of this script rather than a tool the releaser has
# to go find; the EdDSA private key is read from the login keychain and never
# printed.
SIGN_UPDATE="$(find "${DERIVED_DATA}/SourcePackages/artifacts" -name sign_update -path "*/Sparkle/bin/*" -print -quit 2>/dev/null || true)"
if [[ -z "${SIGN_UPDATE}" ]]; then
  echo "error: could not find sign_update under ${DERIVED_DATA}/SourcePackages/artifacts" >&2
  exit 1
fi

echo "==> Signing the appcast payload"
SIGNATURE_FILE="${OUT_DIR}/sparkle-signature.txt"
"${SIGN_UPDATE}" "${ZIP_PATH}" >"${SIGNATURE_FILE}"
SIGNATURE_ATTRS="$(<"${SIGNATURE_FILE}")"

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_PATH}/Contents/Info.plist")"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)"
ZIP_FILENAME="KeeForge-${SHORT_VERSION}-b${BUILD_NUMBER}.zip"
FINAL_ZIP_PATH="${OUT_DIR}/${ZIP_FILENAME}"
mv "${ZIP_PATH}" "${FINAL_ZIP_PATH}"
ZIP_SHA256="$(shasum -a 256 "${FINAL_ZIP_PATH}" | awk '{print $1}')"
ZIP_SIZE="$(stat -f '%z' "${FINAL_ZIP_PATH}")"

# sign_update returns enclosure attributes, normally
# sparkle:edSignature="..." length="...". Keep both the raw value and the
# parsed values so a handoff never has to re-sign the final bytes.
SPARKLE_ED_SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"${SIGNATURE_ATTRS}")"
SPARKLE_LENGTH="$(sed -n 's/.*[[:space:]]\(sparkle:\)\{0,1\}length="\([^"]*\)".*/\2/p' <<<"${SIGNATURE_ATTRS}")"
if [[ -z "${SPARKLE_ED_SIGNATURE}" || -z "${SPARKLE_LENGTH}" ]]; then
  echo "error: sign_update did not return sparkle:edSignature and length attributes" >&2
  exit 1
fi
if [[ "${SPARKLE_LENGTH}" != "${ZIP_SIZE}" ]]; then
  echo "error: Sparkle signature length (${SPARKLE_LENGTH}) does not match zip size (${ZIP_SIZE})" >&2
  exit 1
fi
ARTIFACT_JSON="${KEEFORGE_DIRECT_ARTIFACT_JSON:-${OUT_DIR}/direct-artifact.json}"
SOURCE_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
SOURCE_TREE="$(git -C "${REPO_ROOT}" rev-parse 'HEAD^{tree}')"
mkdir -p "$(dirname "${ARTIFACT_JSON}")"
jq -n \
  --arg version "${SHORT_VERSION}" \
  --arg repoBuild "${BUILD_NUMBER}" \
  --arg commitSHA "${SOURCE_SHA}" \
  --arg sourceTree "${SOURCE_TREE}" \
  --arg rcTag "${RC_TAG}" \
  --arg zipPath "${FINAL_ZIP_PATH}" \
  --arg zipFilename "${ZIP_FILENAME}" \
  --arg sha256 "${ZIP_SHA256}" \
  --arg notarizationSubmissionID "${NOTARIZATION_ID}" \
  --arg notarizationStatus "${NOTARIZATION_STATUS}" \
  --arg sparkleSignature "${SIGNATURE_ATTRS}" \
  --arg sparkleEDSignature "${SPARKLE_ED_SIGNATURE}" \
  --arg sparkleLength "${SPARKLE_LENGTH}" \
  --arg archivePath "${ARCHIVE_PATH}" \
  --arg symbolsPath "${ARCHIVE_PATH}/dSYMs" \
  --arg appPath "${APP_PATH}" \
  --arg feedURL "${BUILT_FEED_URL}" \
  --arg minimumSystemVersion "${MIN_SYSTEM}" \
  --argjson sizeBytes "${ZIP_SIZE}" \
  '{schemaVersion: 1, version: $version, repoBuild: ($repoBuild | tonumber), rcTag: $rcTag, commitSHA: $commitSHA,
    sourceTree: $sourceTree, zipPath: $zipPath, zipFilename: $zipFilename,
    sha256: $sha256, sizeBytes: $sizeBytes, notarizationSubmissionID: $notarizationSubmissionID,
    notarizationStatus: $notarizationStatus,
    sparkleSignature: $sparkleSignature,
    sparkleSignatureAttributes: {"sparkle:edSignature": $sparkleEDSignature, length: $sparkleLength},
    archivePath: $archivePath, symbolsPath: $symbolsPath, appPath: $appPath,
    feedURL: $feedURL, minimumSystemVersion: $minimumSystemVersion}' \
  >"${ARTIFACT_JSON}"

echo
echo "Done. Notarized, stapled app: ${APP_PATH}"
echo "Appcast payload:              ${FINAL_ZIP_PATH}"
echo "Artifact handoff JSON:        ${ARTIFACT_JSON}"
echo "SHA-256:                      ${ZIP_SHA256}"
echo "Size (bytes):                 ${ZIP_SIZE}"
echo "Notarization submission ID:   ${NOTARIZATION_ID}"
echo "Sparkle signature attributes: ${SIGNATURE_FILE}"
echo "Version/build:                ${SHORT_VERSION}/${BUILD_NUMBER}"
echo "Archive:                      ${ARCHIVE_PATH}"
echo "Symbols:                      ${ARCHIVE_PATH}/dSYMs"
echo
echo "Appcast entry for ${BUILT_FEED_URL} — paste into <channel>, newest first:"
echo
cat <<APPCAST_ITEM
        <item>
            <title>${SHORT_VERSION}</title>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_SYSTEM}</sparkle:minimumSystemVersion>
            <sparkle:releaseNotesLink>https://github.com/KeeForge/KeeForge/releases/tag/v${SHORT_VERSION}</sparkle:releaseNotesLink>
            <enclosure url="https://github.com/KeeForge/KeeForge/releases/download/v${SHORT_VERSION}/${ZIP_FILENAME}"
                       ${SIGNATURE_ATTRS}
                       type="application/octet-stream" />
        </item>
APPCAST_ITEM
echo
echo "Stage the appcast and hand off the draft GitHub Release with ci_scripts/release_direct_artifact.sh."
