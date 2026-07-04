#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KEEPASSXC_CLI="${KEEPASSXC_CLI:-}"
if [[ -z "${KEEPASSXC_CLI}" ]]; then
  if command -v keepassxc-cli >/dev/null 2>&1; then
    KEEPASSXC_CLI="$(command -v keepassxc-cli)"
  elif [[ -x "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli" ]]; then
    KEEPASSXC_CLI="/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
  else
    echo "error: keepassxc-cli is required for the KDBX compatibility gate." >&2
    echo "Install KeePassXC or set KEEPASSXC_CLI=/path/to/keepassxc-cli." >&2
    exit 1
  fi
fi

RESULT_BUNDLE="${KDBX_COMPAT_RESULT_BUNDLE:-${REPO_ROOT}/build/KDBXCompatibilityGate.xcresult}"
ATTACHMENT_DIR="${KDBX_COMPAT_ATTACHMENTS_DIR:-${REPO_ROOT}/build/KDBXCompatibilityGateAttachments}"
DESTINATION="${KDBX_COMPAT_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"

rm -rf "${RESULT_BUNDLE}" "${ATTACHMENT_DIR}"
mkdir -p "$(dirname "${RESULT_BUNDLE}")" "${ATTACHMENT_DIR}"

cd "${REPO_ROOT}"

xcodebuild test -project KeeForge.xcodeproj -scheme KeeForge \
  -destination "${DESTINATION}" \
  -only-testing:KeeForgeTests/KDBXCompatibilityArtifactTests \
  -resultBundlePath "${RESULT_BUNDLE}" \
  -quiet

xcrun xcresulttool export attachments \
  --path "${RESULT_BUNDLE}" \
  --output-path "${ATTACHMENT_DIR}"

python3 - "${ATTACHMENT_DIR}" "${KEEPASSXC_CLI}" <<'PY'
import hashlib
import json
import os
import subprocess
import sys
import tempfile

attachment_dir = sys.argv[1]
keepassxc_cli = sys.argv[2]
manifest_name = "kdbx-compatibility-manifest.json"

files_by_name = {}
for root, _, files in os.walk(attachment_dir):
    for file_name in files:
        files_by_name.setdefault(file_name, []).append(os.path.join(root, file_name))

def exported_attachments():
    export_manifest_paths = files_by_name.get("manifest.json", [])
    if not export_manifest_paths:
        return []
    try:
        with open(export_manifest_paths[0], "r", encoding="utf-8") as handle:
            export_manifest = json.load(handle)
    except Exception:
        return []

    attachments = []
    for test_record in export_manifest if isinstance(export_manifest, list) else []:
        attachments.extend(test_record.get("attachments", []))
    return attachments

exported_attachment_records = exported_attachments()

def first_existing_file(file_name):
    if not file_name:
        return None

    matches = files_by_name.get(file_name, [])
    if matches:
        return matches[0]

    expected_stem, expected_ext = os.path.splitext(file_name)
    for attachment in exported_attachment_records:
        suggested_name = attachment.get("suggestedHumanReadableName", "")
        exported_name = attachment.get("exportedFileName")
        if not exported_name:
            continue
        suggested_stem, suggested_ext = os.path.splitext(suggested_name)
        matches_suggested_name = (
            suggested_name == file_name
            or (
                suggested_ext == expected_ext
                and suggested_stem.startswith(f"{expected_stem}_")
            )
        )
        if not matches_suggested_name:
            continue

        exported_matches = files_by_name.get(exported_name, [])
        if exported_matches:
            return exported_matches[0]

    for root, _, files in os.walk(attachment_dir):
        for candidate in files:
            if candidate == file_name:
                return os.path.join(root, candidate)
    return None

manifest_path = first_existing_file(manifest_name)
if manifest_path is None:
    for root, _, files in os.walk(attachment_dir):
        for candidate in files:
            if not candidate.endswith(".json"):
                continue
            candidate_path = os.path.join(root, candidate)
            try:
                with open(candidate_path, "r", encoding="utf-8") as handle:
                    candidate_json = json.load(handle)
            except Exception:
                continue
            if isinstance(candidate_json, dict) and "artifacts" in candidate_json:
                manifest_path = candidate_path
                break
        if manifest_path:
            break

if manifest_path is None:
    print(f"error: {manifest_name} was not exported from the test result bundle", file=sys.stderr)
    sys.exit(1)

with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

failures = []
attachment_checks_verified = 0

def run_keepassxc(args, password):
    process = subprocess.run(
        args,
        input=f"{password}\n",
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return process

def resolve_entry_path(db_path, base_options, password, entry_title, artifact_id, expected_search_terms):
    # Prefer an exact-title search hit so entries that moved (e.g. into the
    # Recycle Bin) still resolve to their current path. Only search if the
    # scenario's own expectedSearchTerms didn't already confirm this title,
    # to avoid masking an unrelated search failure recorded above.
    command = [keepassxc_cli, "search", *base_options, db_path, entry_title]
    result = run_keepassxc(command, password)
    if result.returncode != 0:
        return None, f"{artifact_id}: search for entry {entry_title!r} failed\nstdout: {result.stdout}\nstderr: {result.stderr}"

    for line in result.stdout.splitlines():
        candidate = line.strip()
        if candidate.rsplit("/", 1)[-1] == entry_title:
            return candidate, None

    return None, f"{artifact_id}: could not resolve path for entry {entry_title!r}\nstdout: {result.stdout}"

for artifact in manifest.get("artifacts", []):
    artifact_id = artifact["id"]
    db_path = first_existing_file(artifact["fileName"])
    if db_path is None:
        failures.append(f"{artifact_id}: missing exported database {artifact['fileName']}")
        continue

    key_file_name = artifact.get("keyFileName")
    key_path = first_existing_file(key_file_name) if key_file_name else None
    if key_file_name and key_path is None:
        failures.append(f"{artifact_id}: missing exported key file {key_file_name}")
        continue

    base_options = ["-q"]
    if key_path:
        base_options.extend(["-k", key_path])

    for term in artifact.get("expectedSearchTerms", []):
        command = [keepassxc_cli, "search", *base_options, db_path, term]
        result = run_keepassxc(command, artifact["password"])
        if result.returncode != 0 or term not in result.stdout:
            failures.append(
                f"{artifact_id}: search term {term!r} failed\n"
                f"stdout: {result.stdout}\n"
                f"stderr: {result.stderr}"
            )

    for group_path in artifact.get("expectedGroupPaths", []):
        command = [keepassxc_cli, "ls", *base_options, db_path, group_path]
        result = run_keepassxc(command, artifact["password"])
        if result.returncode != 0:
            failures.append(
                f"{artifact_id}: group path {group_path!r} failed\n"
                f"stdout: {result.stdout}\n"
                f"stderr: {result.stderr}"
            )

    for expected_attachment in artifact.get("expectedAttachments", []):
        entry_title = expected_attachment["entryTitle"]
        attachment_name = expected_attachment["attachmentName"]
        expected_sha256 = expected_attachment["sha256"]

        entry_path, resolve_error = resolve_entry_path(
            db_path, base_options, artifact["password"], entry_title, artifact_id, artifact.get("expectedSearchTerms", [])
        )
        if entry_path is None:
            failures.append(resolve_error)
            continue

        with tempfile.TemporaryDirectory() as export_dir:
            export_path = os.path.join(export_dir, "exported-attachment")
            command = [keepassxc_cli, "attachment-export", *base_options, db_path, entry_path, attachment_name, export_path]
            result = run_keepassxc(command, artifact["password"])
            if result.returncode != 0:
                failures.append(
                    f"{artifact_id}: attachment-export for {entry_title!r}/{attachment_name!r} failed\n"
                    f"stdout: {result.stdout}\n"
                    f"stderr: {result.stderr}"
                )
                continue

            with open(export_path, "rb") as handle:
                actual_sha256 = hashlib.sha256(handle.read()).hexdigest()

            if actual_sha256 != expected_sha256:
                failures.append(
                    f"{artifact_id}: attachment {entry_title!r}/{attachment_name!r} sha256 mismatch "
                    f"(expected {expected_sha256}, got {actual_sha256})"
                )
            else:
                attachment_checks_verified += 1

if failures:
    print("KDBX compatibility gate failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    sys.exit(1)

print(
    f"KDBX compatibility gate passed for {len(manifest.get('artifacts', []))} artifacts "
    f"({attachment_checks_verified} attachment checks verified)."
)
PY
