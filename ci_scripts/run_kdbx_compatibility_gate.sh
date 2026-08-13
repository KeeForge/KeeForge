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
  -only-testing:KeeForgeTests/KDBXCompatibilityTests \
  -resultBundlePath "${RESULT_BUNDLE}" \
  -quiet

xcrun xcresulttool export attachments \
  --path "${RESULT_BUNDLE}" \
  --output-path "${ATTACHMENT_DIR}"

python3 - "${ATTACHMENT_DIR}" "${KEEPASSXC_CLI}" <<'PY'
import base64
import hashlib
import hmac
import json
import os
import struct
import subprocess
import sys
import tempfile
import time

attachment_dir = sys.argv[1]
keepassxc_cli = sys.argv[2]

files_by_name = {}
all_files = []
for root, _, files in os.walk(attachment_dir):
    for file_name in files:
        path = os.path.join(root, file_name)
        files_by_name.setdefault(file_name, []).append(path)
        all_files.append(path)

def exported_attachments():
    # xcresulttool writes its own index next to the exported blobs, mapping the
    # attachment name XCTest saw ("suggestedHumanReadableName") to the possibly
    # mangled name on disk ("exportedFileName"). Load-bearing: identically named
    # attachments from different tests get a `_1`-style suffix on export.
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

    return None

# Every KDBXCompatibilityTests method that runs scenarios attaches one manifest
# fragment describing only the artifacts it produced. Find them by content, not
# by name, so xcresulttool's export-name mangling cannot hide one: any exported
# file that parses as a JSON object with an "artifacts" key is a fragment.
# (xcresulttool's own index is a JSON *list*, so it never matches.)
fragments = []
for path in all_files:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            parsed = json.load(handle)
    except Exception:
        continue
    if isinstance(parsed, dict) and "artifacts" in parsed:
        fragments.append((path, parsed))

if not fragments:
    print("error: no KDBX compatibility manifest fragments were exported from the test result bundle", file=sys.stderr)
    sys.exit(1)

merged_artifacts = {}
expected_artifact_ids = set()
failures = []

for path, fragment in fragments:
    expected_artifact_ids.update(fragment.get("expectedArtifactIDs", []))
    for artifact in fragment.get("artifacts", []):
        artifact_id = artifact["id"]
        existing = merged_artifacts.get(artifact_id)
        if existing is None:
            merged_artifacts[artifact_id] = artifact
        elif existing != artifact:
            failures.append(
                f"{artifact_id}: conflicting manifest entries across fragments "
                f"(second copy from {os.path.basename(path)})"
            )

missing_artifact_ids = sorted(expected_artifact_ids - set(merged_artifacts))
if missing_artifact_ids:
    failures.append(
        "the suite declared artifacts that no test method emitted: "
        + ", ".join(missing_artifact_ids)
    )

artifacts = [merged_artifacts[key] for key in sorted(merged_artifacts)]

attachment_checks_verified = 0
password_checks_verified = 0
totp_checks_verified = 0
entry_path_cache = {}

TOTP_HASHES = {"SHA1": hashlib.sha1, "SHA256": hashlib.sha256, "SHA512": hashlib.sha512}

def reference_totp(secret_base32, period, digits, algorithm, at_time):
    # RFC 6238, implemented independently of both KeeForge and KeePassXC so
    # the comparison is a genuine three-way agreement on the enrolled secret.
    key = base64.b32decode(secret_base32 + "=" * (-len(secret_base32) % 8), casefold=True)
    counter = struct.pack(">Q", int(at_time // period))
    digest = hmac.new(key, counter, TOTP_HASHES[algorithm]).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
    return str(value % 10 ** digits).zfill(digits)

def run_keepassxc(args, password):
    process = subprocess.run(
        args,
        input=f"{password}\n",
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return process

def resolve_entry_path(db_path, base_options, password, entry_title, artifact_id):
    # Resolve by exact-title search hit so entries that moved (e.g. into the
    # Recycle Bin) or were renamed by the edit still resolve to their current
    # path. Cached: several checks on one artifact often share an entry.
    cache_key = (db_path, entry_title)
    if cache_key in entry_path_cache:
        return entry_path_cache[cache_key]

    command = [keepassxc_cli, "search", *base_options, db_path, entry_title]
    result = run_keepassxc(command, password)
    if result.returncode != 0:
        resolved = (None, f"{artifact_id}: search for entry {entry_title!r} failed\nstdout: {result.stdout}\nstderr: {result.stderr}")
    else:
        resolved = (None, f"{artifact_id}: could not resolve path for entry {entry_title!r}\nstdout: {result.stdout}")
        for line in result.stdout.splitlines():
            candidate = line.strip()
            if candidate.rsplit("/", 1)[-1] == entry_title:
                resolved = (candidate, None)
                break

    entry_path_cache[cache_key] = resolved
    return resolved

for artifact in artifacts:
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
            db_path, base_options, artifact["password"], entry_title, artifact_id
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

    # Protected values: prove an external opener can decrypt what KeeForge
    # wrote into the inner random stream. Searching by title and listing groups
    # only exercises plaintext XML, so an inner-stream implementation that is
    # self-consistent but non-conforming would otherwise pass the whole gate.
    for expected_password in artifact.get("expectedPasswords", []):
        entry_title = expected_password["entryTitle"]
        expected_value = expected_password["password"]

        entry_path, resolve_error = resolve_entry_path(
            db_path, base_options, artifact["password"], entry_title, artifact_id
        )
        if entry_path is None:
            failures.append(resolve_error)
            continue

        command = [keepassxc_cli, "show", *base_options, "-s", "-a", "Password", db_path, entry_path]
        result = run_keepassxc(command, artifact["password"])
        if result.returncode != 0:
            failures.append(
                f"{artifact_id}: show Password for {entry_title!r} failed\n"
                f"stdout: {result.stdout}\n"
                f"stderr: {result.stderr}"
            )
            continue

        actual_value = result.stdout.rstrip("\r\n")
        if actual_value != expected_value:
            failures.append(
                f"{artifact_id}: protected Password for {entry_title!r} did not round-trip "
                f"(expected {expected_value!r}, got {actual_value!r})"
            )
        else:
            password_checks_verified += 1

    # TOTP: prove the external opener generates a code from what KeeForge
    # enrolled, not merely that the fields survived. The expected code is
    # recomputed here for the time windows in effect just before and just
    # after the CLI call; the call takes well under one period, so the code
    # KeePassXC used is always one of the two — a window rollover mid-check
    # cannot flake the gate.
    for expected_totp in artifact.get("expectedTOTPs", []):
        entry_title = expected_totp["entryTitle"]

        entry_path, resolve_error = resolve_entry_path(
            db_path, base_options, artifact["password"], entry_title, artifact_id
        )
        if entry_path is None:
            failures.append(resolve_error)
            continue

        before_time = time.time()
        command = [keepassxc_cli, "show", *base_options, "-t", db_path, entry_path]
        result = run_keepassxc(command, artifact["password"])
        after_time = time.time()
        if result.returncode != 0:
            failures.append(
                f"{artifact_id}: show --totp for {entry_title!r} failed\n"
                f"stdout: {result.stdout}\n"
                f"stderr: {result.stderr}"
            )
            continue

        actual_code = result.stdout.strip()
        acceptable_codes = {
            reference_totp(
                expected_totp["secret"],
                expected_totp["period"],
                expected_totp["digits"],
                expected_totp["algorithm"],
                at_time,
            )
            for at_time in (before_time, after_time)
        }
        if actual_code not in acceptable_codes:
            failures.append(
                f"{artifact_id}: TOTP for {entry_title!r} did not match the reference "
                f"implementation (expected one of {sorted(acceptable_codes)}, got {actual_code!r})"
            )
        else:
            totp_checks_verified += 1

if failures:
    print("KDBX compatibility gate failed:", file=sys.stderr)
    for failure in failures:
        print(f"- {failure}", file=sys.stderr)
    sys.exit(1)

print(
    f"KDBX compatibility gate passed for {len(artifacts)} artifacts "
    f"({attachment_checks_verified} attachment checks, "
    f"{password_checks_verified} protected-password checks, "
    f"{totp_checks_verified} TOTP checks verified)."
)

if totp_checks_verified == 0:
    print("error: no TOTP checks ran — the enrollment artifacts lost their expectations", file=sys.stderr)
    sys.exit(1)
PY
