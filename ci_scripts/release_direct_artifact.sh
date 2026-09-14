#!/usr/bin/env bash
# Stage a signed direct Mac artifact and, only on explicit handoff, create the
# draft GitHub Release that owns it. Production appcast publication is a
# separate command and is never implicit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPCAST_GENERATOR="${SCRIPT_DIR}/generate_appcast.py"
RELEASE_REPO="KeeForge/KeeForge"

usage() {
  cat >&2 <<'USAGE'
Usage:
  release_direct_artifact.sh stage --artifact-json FILE --output-dir DIR (--input-appcast FILE | --new-feed)
  release_direct_artifact.sh handoff --artifact-json FILE --output-dir DIR --notes-file FILE \
    (--input-appcast FILE | --new-feed)
  release_direct_artifact.sh publish-appcast --staged FILE --metadata FILE \
    --public-verification FILE --destination FILE
  release_direct_artifact.sh verify-public-url --artifact-json FILE --output FILE
  release_direct_artifact.sh verify-live-feed --metadata FILE --url URL --output FILE
  release_direct_artifact.sh --fixture [DIR]

stage creates a complete, unpublished appcast beside a release handoff record.
handoff verifies v{version} and rc/{version}-b{repoBuild} resolve to the
artifact SHA, creates a new draft GitHub Release, uploads the exact zip once,
and verifies the downloaded asset's bytes. It never publishes the appcast.
publish-appcast is intentionally separate. The release body is supplied as a
reviewed --notes-file. It compares the destination with
the staged base hash and atomically replaces it only when they match. A
public-URL verification evidence file is required. verify-public-url performs
an unauthenticated request and therefore must run after the draft is manually
published. --fixture is fully offline: it creates a deterministic zip and
exercises the same local validation/appcast generation without gh, Apple, or a
build.
USAGE
}

die() { echo "error: $*" >&2; exit 1; }

require_command() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

json_value() { jq -er "$1" "$ARTIFACT_JSON"; }

canonical_file() {
  local path="$1"
  [[ -f "$path" && ! -L "$path" ]] || die "expected a regular existing file: $path"
  printf '%s/%s\n' "$(cd "$(dirname "$path")" && pwd -P)" "$(basename "$path")"
}

parse_options() {
  COMMAND="${1:-}"
  [[ -n "$COMMAND" ]] || { usage; exit 2; }
  shift || true
  ARTIFACT_JSON=""
  OUTPUT_DIR=""
  INPUT_APPCAST=""
  STAGED_APPCAST=""
  STAGED_METADATA=""
  PUBLIC_VERIFICATION=""
  DESTINATION=""
  NOTES_FILE=""
  NEW_FEED=0
LIVE_URL=""
  ALLOW_EXISTING_STAGE=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --artifact-json) ARTIFACT_JSON="${2:-}"; shift 2 ;;
      --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
      --input-appcast) INPUT_APPCAST="${2:-}"; shift 2 ;;
      --staged) STAGED_APPCAST="${2:-}"; shift 2 ;;
      --metadata) STAGED_METADATA="${2:-}"; shift 2 ;;
      --public-verification) PUBLIC_VERIFICATION="${2:-}"; shift 2 ;;
      --output) PUBLIC_VERIFICATION="${2:-}"; shift 2 ;;
      --destination) DESTINATION="${2:-}"; shift 2 ;;
      --notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
      --new-feed) NEW_FEED=1; shift ;;
      --url) LIVE_URL="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

validate_artifact() {
  [[ -f "$ARTIFACT_JSON" ]] || die "missing artifact JSON: $ARTIFACT_JSON"
  require_command jq
  local version build filename zip expected_sha expected_size actual_sha actual_size signature_length rc_tag expected_tag
  version="$(json_value '.version | select(type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+([.-][0-9A-Za-z.-]+)?$") )')"
  build="$(json_value '.repoBuild | select(type == "number" and floor == . and . > 0)')"
  json_value '.commitSHA | select(type == "string" and test("^[0-9a-f]{40}$"))' >/dev/null
  json_value '.sourceTree | select(type == "string" and test("^[0-9a-f]{40}$"))' >/dev/null
  rc_tag="$(json_value '.rcTag | strings')"
  filename="$(json_value '.zipFilename | strings')"
  zip="$(json_value '.zipPath | strings')"
  expected_sha="$(json_value '.sha256 | select(type == "string" and test("^[0-9a-f]{64}$"))')"
  expected_size="$(json_value '.sizeBytes | select(type == "number" and . > 0)')"
  signature_length="$(json_value '.sparkleSignatureAttributes.length | strings')"
  [[ "$filename" == "KeeForge-${version}-b${build}.zip" ]] || die "artifact filename/version/build do not agree"
  expected_tag="rc/${version}-b${build}"
  [[ "$rc_tag" == "$expected_tag" ]] || die "artifact RC tag/version/build do not agree"
  zip="$(canonical_file "$zip")"
  [[ "$(basename "$zip")" == "$filename" ]] || die "artifact zip path basename does not match artifact filename"
  ARTIFACT_ZIP_PATH="$zip"
  actual_sha="$(shasum -a 256 "$zip" | awk '{print $1}')"
  actual_size="$(stat -f '%z' "$zip" 2>/dev/null || stat -c '%s' "$zip")"
  [[ "$actual_sha" == "$expected_sha" ]] || die "artifact SHA-256 does not match handoff JSON"
  [[ "$actual_size" == "$expected_size" ]] || die "artifact size does not match handoff JSON"
  [[ "$signature_length" == "$expected_size" ]] || die "Sparkle signature length does not match artifact size"
  [[ "$filename" != */* ]] || die "artifact filename must be a basename"
}

validate_existing_stage() {
  local staged="$1" staged_json="$2" base_present base_sha input_sha expected
  [[ -f "$staged" && -f "$staged_json" ]] || die "incomplete existing stage; choose a fresh output directory"
  [[ "$(shasum -a 256 "$staged" | awk '{print $1}')" == "$(jq -er '.stagedAppcastSHA256 | strings' "$staged_json")" ]] \
    || die "existing staged appcast does not match its metadata hash"
  [[ "$(canonical_file "$(jq -er '.appcastPath | strings' "$staged_json")")" == "$(canonical_file "$staged")" ]] \
    || die "existing staged metadata points at a different appcast"
  for expected in version repoBuild rcTag commitSHA sourceTree sha256 sizeBytes; do
    [[ "$(jq -cer ".$expected" "$staged_json")" == "$(jq -cer ".$expected" "$ARTIFACT_JSON")" ]] \
      || die "existing stage ${expected} does not match artifact identity"
  done
  base_present="$(jq -r 'if .baseAppcast.present == true then "true" else "false" end' "$staged_json")"
  base_sha="$(jq -r '.baseAppcast.sha256 // empty' "$staged_json")"
  if [[ -n "$INPUT_APPCAST" ]]; then
    INPUT_APPCAST="$(canonical_file "$INPUT_APPCAST")"
    input_sha="$(shasum -a 256 "$INPUT_APPCAST" | awk '{print $1}')"
    [[ "$base_present" == true && "$base_sha" == "$input_sha" ]] \
      || die "existing stage base does not match the supplied input appcast"
  else
    [[ "$base_present" == false ]] || die "existing stage was not created with --new-feed"
  fi
  echo "resumed exact staged appcast: $staged"
}

stage_appcast() {
  [[ -n "$OUTPUT_DIR" ]] || die "--output-dir is required"
  [[ -n "$INPUT_APPCAST" || "$NEW_FEED" == 1 ]] || die "stage requires an existing --input-appcast or explicit --new-feed"
  [[ -z "$INPUT_APPCAST" || "$NEW_FEED" == 0 ]] || die "--input-appcast and --new-feed cannot be combined"
  mkdir -p "$OUTPUT_DIR"
  local staged_json staged base_present base_sha staged_sha
  staged="${OUTPUT_DIR}/appcast.xml"
  staged_json="${OUTPUT_DIR}/staged-appcast.json"
  if [[ -e "$staged" || -e "$staged_json" ]]; then
    [[ "$ALLOW_EXISTING_STAGE" == 1 ]] || die "refusing to replace an existing staged feed; choose a fresh output directory"
    validate_existing_stage "$staged" "$staged_json"
    return
  fi
  if [[ -n "$INPUT_APPCAST" ]]; then
    INPUT_APPCAST="$(canonical_file "$INPUT_APPCAST")"
    base_present=true
    base_sha="$(shasum -a 256 "$INPUT_APPCAST" | awk '{print $1}')"
  else
    base_present=false
    base_sha=""
  fi
  local -a input_args=()
  [[ -n "$INPUT_APPCAST" ]] && input_args+=(--input "$INPUT_APPCAST")
  python3 "$APPCAST_GENERATOR" --artifact-json "$ARTIFACT_JSON" --output "$staged" "${input_args[@]}" >/dev/null
  local signature length filename rc_tag commit_sha source_tree
  signature="$(json_value '.sparkleSignatureAttributes["sparkle:edSignature"] | strings')"
  length="$(json_value '.sparkleSignatureAttributes.length | strings')"
  filename="$(json_value '.zipFilename | strings')"
  rc_tag="$(json_value '.rcTag | strings')"
  commit_sha="$(json_value '.commitSHA | strings')"
  source_tree="$(json_value '.sourceTree | strings')"
  grep -Fq "sparkle:edSignature=\"${signature}\"" "$staged" || die "staged appcast signature differs from artifact JSON"
  grep -Fq "length=\"${length}\"" "$staged" || die "staged appcast length differs from artifact JSON"
  grep -Fq "/${filename}\"" "$staged" || die "staged appcast does not point at exact asset"
  staged_sha="$(shasum -a 256 "$staged" | awk '{print $1}')"
  jq -n \
    --arg version "$(json_value '.version | strings')" \
    --arg repoBuild "$(json_value '.repoBuild | tostring')" \
    --arg appcastPath "$staged" \
    --arg zipFilename "$(json_value '.zipFilename | strings')" \
    --arg sha256 "$(json_value '.sha256 | strings')" \
    --arg rcTag "$rc_tag" --arg commitSHA "$commit_sha" --arg sourceTree "$source_tree" \
    --arg baseSha "$base_sha" \
    --arg stagedSha "$staged_sha" \
    --argjson basePresent "$base_present" \
    --argjson sizeBytes "$(json_value '.sizeBytes')" \
    '{schemaVersion: 1, version: $version, repoBuild: ($repoBuild | tonumber), rcTag: $rcTag, commitSHA: $commitSHA, sourceTree: $sourceTree, appcastPath: $appcastPath,
      zipFilename: $zipFilename, sha256: $sha256, sizeBytes: $sizeBytes,
      baseAppcast: {present: $basePresent, sha256: (if $basePresent then $baseSha else null end)},
      stagedAppcastSHA256: $stagedSha, publication: "staged"}' \
    >"$staged_json"
  echo "staged appcast: $staged"
  echo "staged handoff: $staged_json"
}

verify_accepted_tag() {
  local version build sha vtag rctag vsha rcsha remote_vsha remote_rcsha
  version="$(json_value '.version | strings')"
  build="$(json_value '.repoBuild | tostring')"
  sha="$(json_value '.commitSHA | strings')"
  vtag="v${version}"
  rctag="rc/${version}-b${build}"
  vsha="$(git -C "$REPO_ROOT" rev-parse "${vtag}^{commit}" 2>/dev/null || true)"
  rcsha="$(git -C "$REPO_ROOT" rev-parse "${rctag}^{commit}" 2>/dev/null || true)"
  [[ -n "$vsha" ]] || die "accepted tag ${vtag} is missing locally"
  [[ -n "$rcsha" ]] || die "RC tag ${rctag} is missing locally"
  [[ "$vsha" == "$sha" && "$rcsha" == "$sha" ]] || die "v tag, RC tag, and artifact SHA differ"
  remote_vsha="$(origin_tag_sha "$vtag" || true)"
  remote_rcsha="$(origin_tag_sha "$rctag" || true)"
  [[ "$remote_vsha" == "$sha" ]] || die "origin tag ${vtag} does not resolve to artifact SHA"
  [[ "$remote_rcsha" == "$sha" ]] || die "origin tag ${rctag} does not resolve to artifact SHA"
  echo "verified local and origin tags: ${vtag} and ${rctag} -> ${sha}"
}

origin_tag_sha() {
  local tag="$1" refs deref direct
  refs="$(git -C "$REPO_ROOT" ls-remote origin "refs/tags/${tag}" "refs/tags/${tag}^{}")" || return 1
  deref="$(awk '$2 ~ /\^\{\}$/ {print $1; exit}' <<<"$refs")"
  if [[ -n "$deref" ]]; then
    printf '%s\n' "$deref"
  else
    direct="$(awk 'NR == 1 {print $1; exit}' <<<"$refs")"
    [[ -n "$direct" ]] || return 1
    printf '%s\n' "$direct"
  fi
}

verify_downloaded_path() {
  local path expected_sha expected_size remote_sha remote_size
  path="$1"
  expected_sha="$(json_value '.sha256')"
  expected_size="$(json_value '.sizeBytes')"
  [[ -f "$path" ]] || die "missing downloaded asset: $path"
  remote_sha="$(shasum -a 256 "$path" | awk '{print $1}')"
  remote_size="$(stat -f '%z' "$path" 2>/dev/null || stat -c '%s' "$path")"
  [[ "$remote_sha" == "$expected_sha" ]] || die "downloaded asset SHA-256 does not match local artifact"
  [[ "$remote_size" == "$expected_size" ]] || die "downloaded asset size does not match local artifact"
  echo "verified downloaded asset: ${path} (sha256=${remote_sha}, sizeBytes=${remote_size})"
}

verify_public_url() {
  local version filename expected_sha expected_size url temp output
  version="$(json_value '.version | strings')"
  filename="$(json_value '.zipFilename | strings')"
  expected_sha="$(json_value '.sha256 | strings')"
  expected_size="$(json_value '.sizeBytes')"
  url="https://github.com/${RELEASE_REPO}/releases/download/v${version}/${filename}"
  temp="$(mktemp "${TMPDIR:-/tmp}/keeforge-direct-verify.XXXXXX")"
  trap 'rm -f "$temp"' EXIT
  # This must be unauthenticated: a draft/private asset must not satisfy the
  # final public-accessibility check via a local GitHub credential.
  curl -fsSL -H 'Accept: application/octet-stream' "$url" -o "$temp"
  verify_downloaded_path "$temp" >/dev/null
  output="${PUBLIC_VERIFICATION:-}"
  [[ -n "$output" ]] || die "--output is required for public URL verification"
  mkdir -p "$(dirname "$output")"
  jq -n --arg url "$url" --arg sha "$expected_sha" --argjson size "$expected_size" \
    '{schemaVersion: 1, kind: "public-url", url: $url, sha256: $sha, sizeBytes: $size, verified: true}' >"$output"
  rm -f "$temp"
  trap - EXIT
  echo "verified public URL: ${url}; evidence: ${output}"
}

verify_draft_release() {
  local version filename tag release_json release_error asset_count asset_url temp
  version="$(json_value '.version | strings')"
  filename="$(json_value '.zipFilename | strings')"
  tag="v${version}"
  release_error="${OUTPUT_DIR}/release-view.error"
  if ! release_json="$(gh api "repos/${RELEASE_REPO}/releases/tags/${tag}" 2>"$release_error")"; then
    if ! grep -Eiq 'not found|404' "$release_error"; then
      die "could not safely determine whether GitHub Release ${tag} exists"
    fi
    gh release create "$tag" --repo "$RELEASE_REPO" --draft --verify-tag \
      --title "KeeForge ${version}" --notes-file "$NOTES_FILE"
    release_json="$(gh api "repos/${RELEASE_REPO}/releases/tags/${tag}")" || die "cannot read newly-created draft release ${tag}"
  fi
  [[ "$(jq -r '.tag_name // empty' <<<"$release_json")" == "$tag" ]] || die "draft release tag does not match ${tag}"
  [[ "$(jq -r '.draft' <<<"$release_json")" == true ]] || die "GitHub Release ${tag} is published; refusing to modify it"
  asset_count="$(jq --arg filename "$filename" '[.assets[] | select(.name == $filename)] | length' <<<"$release_json")"
  [[ "$(jq '[.assets[]] | length' <<<"$release_json")" == "$asset_count" ]] || die "draft release contains an unexpected asset"
  if [[ "$asset_count" == 0 ]]; then
    gh release upload "$tag" "$ARTIFACT_ZIP_PATH" --repo "$RELEASE_REPO"
    release_json="$(gh api "repos/${RELEASE_REPO}/releases/tags/${tag}")" || die "cannot read draft release after upload"
  fi
  asset_count="$(jq --arg filename "$filename" '[.assets[] | select(.name == $filename)] | length' <<<"$release_json")"
  [[ "$asset_count" == 1 ]] || die "draft release must contain exactly one expected asset"
  asset_url="$(jq -er --arg filename "$filename" '.assets[] | select(.name == $filename) | .url' <<<"$release_json")"
  temp="$(mktemp "${TMPDIR:-/tmp}/keeforge-draft-verify.XXXXXX")"
  trap 'rm -f "$temp"' EXIT
  gh api -H 'Accept: application/octet-stream' "$asset_url" >"$temp"
  verify_downloaded_path "$temp" >/dev/null
  rm -f "$temp"
  trap - EXIT
  jq -n --arg tag "$tag" --arg filename "$filename" --arg sha "$(json_value '.sha256')" \
    --argjson size "$(json_value '.sizeBytes')" \
    '{schemaVersion: 1, kind: "draft-release-asset", tag: $tag, zipFilename: $filename, sha256: $sha, sizeBytes: $size, verified: true}' \
    >"${OUTPUT_DIR}/draft-verification.json"
  echo "verified draft asset: ${filename}; evidence: ${OUTPUT_DIR}/draft-verification.json"
}

handoff() {
  [[ -n "$ARTIFACT_JSON" && -n "$OUTPUT_DIR" && -n "$NOTES_FILE" ]] || die "handoff requires --artifact-json, --output-dir, and --notes-file"
  NOTES_FILE="$(canonical_file "$NOTES_FILE")"
  [[ -s "$NOTES_FILE" ]] || die "--notes-file must not be empty"
  require_command gh
  require_command python3
  validate_artifact
  verify_accepted_tag
  ALLOW_EXISTING_STAGE=1
  stage_appcast
  local version filename tag
  version="$(json_value '.version | strings')"
  filename="$(json_value '.zipFilename | strings')"
  tag="v${version}"
  verify_draft_release
  echo "draft release ready: ${tag}; appcast remains staged at ${OUTPUT_DIR}/appcast.xml"
}

publish_appcast() {
  [[ -n "$STAGED_APPCAST" && -n "$STAGED_METADATA" && -n "$PUBLIC_VERIFICATION" && -n "$DESTINATION" ]] || die "publish-appcast requires --staged, --metadata, --public-verification, and --destination"
  STAGED_APPCAST="$(canonical_file "$STAGED_APPCAST")"
  STAGED_METADATA="$(canonical_file "$STAGED_METADATA")"
  PUBLIC_VERIFICATION="$(canonical_file "$PUBLIC_VERIFICATION")"
  local staged_sha expected_staged_sha base_present base_sha destination_sha expected_url version filename evidence_url metadata_path
  staged_sha="$(shasum -a 256 "$STAGED_APPCAST" | awk '{print $1}')"
  expected_staged_sha="$(jq -er '.stagedAppcastSHA256 | strings' "$STAGED_METADATA")"
  [[ "$staged_sha" == "$expected_staged_sha" ]] || die "staged appcast was modified after staging"
  metadata_path="$(canonical_file "$(jq -er '.appcastPath | strings' "$STAGED_METADATA")")"
  [[ "$metadata_path" == "$STAGED_APPCAST" ]] || die "staged metadata points at a different appcast"
  version="$(jq -er '.version | strings' "$STAGED_METADATA")"
  filename="$(jq -er '.zipFilename | strings' "$STAGED_METADATA")"
  expected_url="https://github.com/${RELEASE_REPO}/releases/download/v${version}/${filename}"
  evidence_url="$(jq -er '.url | strings' "$PUBLIC_VERIFICATION")"
  [[ "$evidence_url" == "$expected_url" ]] || die "public verification is for a different enclosure URL"
  [[ "$(jq -er '.verified == true' "$PUBLIC_VERIFICATION")" == true ]] || die "public URL verification is not marked successful"
  [[ "$(jq -er '.sha256' "$PUBLIC_VERIFICATION")" == "$(jq -er '.sha256' "$STAGED_METADATA")" ]] || die "public URL hash differs from staged artifact"
  [[ "$(jq -er '.sizeBytes' "$PUBLIC_VERIFICATION")" == "$(jq -er '.sizeBytes' "$STAGED_METADATA")" ]] || die "public URL size differs from staged artifact"
  base_present="$(jq -r 'if .baseAppcast.present == true then "true" else "false" end' "$STAGED_METADATA")"
  base_sha="$(jq -r '.baseAppcast.sha256 // empty' "$STAGED_METADATA")"
  if [[ "$base_present" == true ]]; then
    [[ -f "$DESTINATION" ]] || die "destination disappeared; refusing compare-and-swap"
    destination_sha="$(shasum -a 256 "$DESTINATION" | awk '{print $1}')"
    [[ "$destination_sha" == "$base_sha" ]] || die "destination appcast changed since staging"
  else
    [[ ! -e "$DESTINATION" ]] || die "destination appeared although staging recorded explicit absence"
  fi
  mkdir -p "$(dirname "$DESTINATION")"
  local temp
  temp="$(mktemp "$(dirname "$DESTINATION")/.appcast-publish.XXXXXX")"
  cp "$STAGED_APPCAST" "$temp"
  # Recheck immediately before the atomic rename to narrow the compare-and-swap race.
  if [[ "$base_present" == true ]]; then
    destination_sha="$(shasum -a 256 "$DESTINATION" | awk '{print $1}')"
    [[ "$destination_sha" == "$base_sha" ]] || { rm -f "$temp"; die "destination changed before atomic publish"; }
  else
    [[ ! -e "$DESTINATION" ]] || { rm -f "$temp"; die "destination appeared before atomic publish"; }
  fi
  mv -f "$temp" "$DESTINATION"
  echo "atomically published appcast to explicit destination: $DESTINATION"
}

verify_live_feed() {
  [[ -n "$STAGED_METADATA" && -n "$LIVE_URL" && -n "$PUBLIC_VERIFICATION" ]] || die "verify-live-feed requires --metadata, --url, and --output"
  STAGED_METADATA="$(canonical_file "$STAGED_METADATA")"
  require_command curl
  local temp actual base_present base_sha staged_sha matched
  temp="$(mktemp "${TMPDIR:-/tmp}/keeforge-feed-verify.XXXXXX")"
  trap 'rm -f "$temp"' EXIT
  curl -fsSL "$LIVE_URL" -o "$temp"
  actual="$(shasum -a 256 "$temp" | awk '{print $1}')"
  base_present="$(jq -r 'if .baseAppcast.present == true then "true" else "false" end' "$STAGED_METADATA")"
  base_sha="$(jq -r '.baseAppcast.sha256 // empty' "$STAGED_METADATA")"
  staged_sha="$(jq -er '.stagedAppcastSHA256 | strings' "$STAGED_METADATA")"
  matched=""
  if [[ "$actual" == "$staged_sha" ]]; then matched="staged"; fi
  if [[ "$base_present" == true && "$actual" == "$base_sha" ]]; then matched="base"; fi
  [[ -n "$matched" ]] || die "live feed SHA matches neither staged nor recorded base feed"
  mkdir -p "$(dirname "$PUBLIC_VERIFICATION")"
  jq -n --arg url "$LIVE_URL" --arg sha "$actual" --arg match "$matched" \
    '{schemaVersion: 1, kind: "live-feed", url: $url, sha256: $sha, matches: $match, verified: true}' >"$PUBLIC_VERIFICATION"
  rm -f "$temp"; trap - EXIT
  echo "verified live feed ($matched): $LIVE_URL; evidence: $PUBLIC_VERIFICATION"
}

fixture() {
  require_command jq
  local dir="${1:-${REPO_ROOT}/scratch/direct-release-fixture}" zip payload artifact old notes
  mkdir -p "$dir"
  payload="${dir}/fixture-payload.txt"
  zip="${dir}/KeeForge-9.9.9-b999.zip"
  artifact="${dir}/direct-artifact.json"
  old="${dir}/old-appcast.xml"
  printf '%s\n' 'KeeForge direct fixture; no build, notarization, network, or GitHub.' >"$payload"
  rm -f "$zip"
  (cd "$dir" && zip -q "$zip" "$(basename "$payload")")
  local sha size
  sha="$(shasum -a 256 "$zip" | awk '{print $1}')"
  size="$(stat -f '%z' "$zip" 2>/dev/null || stat -c '%s' "$zip")"
  cat >"$old" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>KeeForge for Mac</title><item><title>9.9.8</title><sparkle:version>998</sparkle:version><sparkle:shortVersionString>9.9.8</sparkle:shortVersionString></item></channel></rss>
XML
  jq -n --arg zip "${dir}/./$(basename "$zip")" --arg sha "$sha" --argjson size "$size" \
    '{schemaVersion: 1, version: "9.9.9", repoBuild: 999, rcTag: "rc/9.9.9-b999", commitSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", sourceTree: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      zipPath: $zip, zipFilename: "KeeForge-9.9.9-b999.zip", sha256: $sha, sizeBytes: $size,
      notarizationSubmissionID: "fixture-notarization", sparkleSignature: "sparkle:edSignature=\"fixture-signature\" length=\"\($size)\"",
      sparkleSignatureAttributes: {"sparkle:edSignature": "fixture-signature", length: ($size|tostring)},
      archivePath: "fixture/archive.xcarchive", symbolsPath: "fixture/archive.xcarchive/dSYMs",
      appPath: "fixture/KeeForge.app", feedURL: "https://keeforge.com/appcast.xml", minimumSystemVersion: "15.0"}' \
    >"$artifact"
  ARTIFACT_JSON="$artifact" OUTPUT_DIR="$dir/staged" INPUT_APPCAST="$old" NEW_FEED=0
  validate_artifact
  stage_appcast >&2
  ALLOW_EXISTING_STAGE=1
  stage_appcast >&2
  ALLOW_EXISTING_STAGE=0
  verify_downloaded_path "$zip" >&2
  STAGED_APPCAST="$dir/staged/appcast.xml"
  STAGED_METADATA="$dir/staged/staged-appcast.json"
  PUBLIC_VERIFICATION="$dir/public-verification.json"
  DESTINATION="$dir/published-appcast.xml"
  jq -n --arg version "9.9.9" --arg filename "KeeForge-9.9.9-b999.zip" --arg sha "$sha" --argjson size "$size" \
    '{schemaVersion: 1, kind: "public-url", url: ("https://github.com/KeeForge/KeeForge/releases/download/v" + $version + "/" + $filename), sha256: $sha, sizeBytes: $size, verified: true}' \
    >"$PUBLIC_VERIFICATION"
  cp "$old" "$DESTINATION"
  publish_appcast >&2
  STAGED_METADATA="$dir/staged/staged-appcast.json" LIVE_URL="file://${DESTINATION}" \
    PUBLIC_VERIFICATION="$dir/live-feed.json" verify_live_feed >&2
  grep -Fq '9.9.8' "$DESTINATION" || die "fixture publication lost the older appcast item"
  python3 - "$DESTINATION" <<'PY' || die "fixture releaseNotesLink does not point at the v9.9.9 release notes"
import sys
import xml.etree.ElementTree as ET
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(sys.argv[1]).getroot().find("channel").findall("item")
links = {item.findtext(f"{ns}shortVersionString"): item.findtext(f"{ns}releaseNotesLink") for item in items}
sys.exit(links.get("9.9.9") != "https://github.com/KeeForge/KeeForge/releases/tag/v9.9.9")
PY
  local mismatch_destination="$dir/mismatched-appcast.xml"
  printf '%s\n' 'changed after staging' >"$mismatch_destination"
  if "$0" publish-appcast --staged "$STAGED_APPCAST" --metadata "$STAGED_METADATA" \
      --public-verification "$PUBLIC_VERIFICATION" --destination "$mismatch_destination" >/dev/null 2>&1; then
    die "fixture base-mismatch publication unexpectedly succeeded"
  fi
  if python3 "$APPCAST_GENERATOR" --artifact-json "$artifact" --input "$STAGED_APPCAST" --output "$dir/duplicate.xml" >/dev/null 2>&1; then
    die "fixture duplicate appcast item unexpectedly succeeded"
  fi
  # An explicit first-release stage records absence; a stale live base still
  # refuses publication. This remains local and has no release side effects.
  ARTIFACT_JSON="$artifact" OUTPUT_DIR="$dir/new-feed" INPUT_APPCAST="" NEW_FEED=1
  stage_appcast >&2
  cp "$old" "$dir/new-feed/stale.xml"
  if "$0" publish-appcast --staged "$dir/new-feed/appcast.xml" --metadata "$dir/new-feed/staged-appcast.json" \
      --public-verification "$PUBLIC_VERIFICATION" --destination "$dir/new-feed/stale.xml" >/dev/null 2>&1; then
    die "fixture accepted a stale feed where explicit absence was staged"
  fi
  if "$0" stage --artifact-json "$artifact" --output-dir "$dir/staged" --input-appcast "$old" >/dev/null 2>&1; then
    die "fixture allowed a respin to overwrite an existing staged feed"
  fi
  jq -cn --arg mode fixture --arg artifact "$artifact" --arg appcast "$dir/staged/appcast.xml" \
    '{mode: $mode, artifactJSON: $artifact, stagedAppcast: $appcast, network: false, github: false, notarization: false, draftVerification: "local-byte-check", pathEquivalence: true, stageResumeVerified: true, atomicPublish: true, baseMismatchRefused: true, absentBaseRefused: true, respinOverwriteRefused: true, duplicateRefused: true}'
}

if [[ "${1:-}" == "--fixture" ]]; then
  fixture "${2:-}"
  exit 0
fi

parse_options "$@"
case "$COMMAND" in
  stage)
    [[ -n "$ARTIFACT_JSON" && -n "$OUTPUT_DIR" ]] || die "stage requires --artifact-json and --output-dir"
    validate_artifact
    stage_appcast
    ;;
  handoff) handoff ;;
  verify-public-url)
    [[ -n "$ARTIFACT_JSON" ]] || die "verify-public-url requires --artifact-json"
    require_command curl
    verify_public_url
    ;;
  verify-live-feed) verify_live_feed ;;
  publish-appcast) publish_appcast ;;
  *) usage; exit 2 ;;
esac
