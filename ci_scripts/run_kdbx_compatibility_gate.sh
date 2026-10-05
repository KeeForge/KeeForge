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
# The gate runs per platform: the iOS scheme by default, the macOS scheme when
# KDBX_COMPAT_SCHEME=KeeForgeMac (its test target compiles the same KeeForgeTests
# sources, so only the target prefix changes).
SCHEME="${KDBX_COMPAT_SCHEME:-KeeForge}"
if [[ "${SCHEME}" == "KeeForgeMac" ]]; then
  TEST_TARGET="${KDBX_COMPAT_TEST_TARGET:-KeeForgeMacTests}"
  DESTINATION="${KDBX_COMPAT_DESTINATION:-platform=macOS}"
else
  TEST_TARGET="${KDBX_COMPAT_TEST_TARGET:-KeeForgeTests}"
  DESTINATION="${KDBX_COMPAT_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
fi

rm -rf "${RESULT_BUNDLE}" "${ATTACHMENT_DIR}"
mkdir -p "$(dirname "${RESULT_BUNDLE}")" "${ATTACHMENT_DIR}"

cd "${REPO_ROOT}"

xcodebuild test -project KeeForge.xcodeproj -scheme "${SCHEME}" \
  -destination "${DESTINATION}" \
  -only-testing:"${TEST_TARGET}/KDBXCompatibilityTests" \
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
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

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
custom_field_checks_verified = 0
expiry_checks_verified = 0
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

def verify_field_set(entry, expected, label):
    strings = {}
    for item in entry.findall("String"):
        name = item.findtext("Key")
        if name in strings:
            raise ValueError(f"{label}: duplicate field {name!r}")
        strings[name] = item.find("Value")
    for field in expected["fields"]:
        name = field["name"]
        value = strings.get(name)
        if value is None:
            raise ValueError(f"{label}: missing field {name!r}")
        # KeePassXC emits literal CR on XML export; XML parsing normalizes it
        # to LF. A raw `show` check below verifies the original CR survived.
        exported_value = field["value"].replace("\r\n", "\n").replace("\r", "\n")
        if (value.text or "") != exported_value:
            raise ValueError(f"{label}: incorrect value for field {name!r}")
        # KeePassXC exports decrypted values and preserves their protection
        # as ProtectInMemory, rather than the on-disk Protected attribute.
        protected = value.get("ProtectInMemory", "False") == "True"
        if protected != field["isProtected"]:
            raise ValueError(f"{label}: incorrect protection for field {name!r}")
    for name in expected["absentFields"]:
        if name in strings:
            raise ValueError(f"{label}: deleted field {name!r} is still present")


def find_live_entry(root, title):
    matches = [
        entry for entry in root.findall(".//Group/Entry")
        if any(item.findtext("Key") == "Title" and item.findtext("Value") == title
               for item in entry.findall("String"))
    ]
    if len(matches) != 1:
        raise ValueError(f"expected exactly one live entry titled {title!r}, found {len(matches)}")
    return matches[0]


def verify_custom_fields(xml, expectations):
    root = ET.fromstring(xml)
    for expected in expectations:
        title = expected["entryTitle"]
        entry = find_live_entry(root, title)
        verify_field_set(entry, expected["current"], title)
        history = entry.findall("History/Entry")
        if len(history) != len(expected["history"]):
            raise ValueError(f"{title}: incorrect history count")
        for index, (version, fields) in enumerate(zip(history, expected["history"])):
            verify_field_set(version, fields, f"{title} history {index}")


KDBX_EPOCH = datetime(1, 1, 1, tzinfo=timezone.utc)

def parse_kdbx_datetime(text):
    # KDBX 4 stores base64 little-endian seconds since 0001-01-01 UTC; older
    # writers and XML exports may use ISO 8601 instead. Accept both.
    text = (text or "").strip()
    try:
        raw = base64.b64decode(text, validate=True)
    except ValueError:
        raw = b""
    if len(text) == 12 and len(raw) == 8:
        return KDBX_EPOCH + timedelta(seconds=struct.unpack("<q", raw)[0])
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def verify_expiries(xml, expectations):
    root = ET.fromstring(xml)
    for expected in expectations:
        title = expected["entryTitle"]
        times = find_live_entry(root, title).find("Times")
        if times is None:
            raise ValueError(f"{title}: no Times element")
        expires = (times.findtext("Expires") or "").strip().lower() == "true"
        if expires != expected["expires"]:
            raise ValueError(f"{title}: Expires is {expires}, expected {expected['expires']}")
        actual = parse_kdbx_datetime(times.findtext("ExpiryTime"))
        if actual != parse_kdbx_datetime(expected["expiryTime"]):
            raise ValueError(f"{title}: ExpiryTime is {actual.isoformat()}, expected {expected['expiryTime']}")


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

    custom_fields = artifact.get("expectedCustomFields", [])
    if custom_fields:
        command = [keepassxc_cli, "export", *base_options, "-f", "xml", db_path]
        result = run_keepassxc(command, artifact["password"])
        if result.returncode != 0:
            failures.append(f"{artifact_id}: XML export failed\nstderr: {result.stderr}")
        else:
            try:
                verify_custom_fields(result.stdout, custom_fields)
            except (ET.ParseError, ValueError) as error:
                failures.append(f"{artifact_id}: {error}")
            else:
                custom_field_checks_verified += len(custom_fields)

        for expected in custom_fields:
            for field in expected["current"]["fields"]:
                if "\r" not in field["value"]:
                    continue
                entry_path, resolve_error = resolve_entry_path(
                    db_path, base_options, artifact["password"], expected["entryTitle"], artifact_id
                )
                if entry_path is None:
                    failures.append(resolve_error)
                    continue
                command = [keepassxc_cli, "show", *base_options, "-s", "-a", field["name"], db_path, entry_path]
                raw_result = subprocess.run(
                    command,
                    input=(artifact["password"] + "\n").encode("utf-8"),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                if raw_result.returncode != 0:
                    failures.append(f"{artifact_id}: could not read {field['name']!r} in KeePassXC")
                    continue
                actual = raw_result.stdout.decode("utf-8").removesuffix("\n")
                if actual != field["value"]:
                    failures.append(f"{artifact_id}: KeePassXC changed carriage returns in {field['name']!r}")

    expiries = artifact.get("expectedExpiries", [])
    if expiries:
        command = [keepassxc_cli, "export", *base_options, "-f", "xml", db_path]
        result = run_keepassxc(command, artifact["password"])
        if result.returncode != 0:
            failures.append(f"{artifact_id}: XML export failed\nstderr: {result.stderr}")
        else:
            try:
                verify_expiries(result.stdout, expiries)
            except (ET.ParseError, ValueError) as error:
                failures.append(f"{artifact_id}: {error}")
            else:
                expiry_checks_verified += len(expiries)

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

if custom_field_checks_verified == 0:
    print("error: no custom-field checks ran — the edit artifact lost its expectations", file=sys.stderr)
    sys.exit(1)

if totp_checks_verified == 0:
    print("error: no TOTP checks ran — the enrollment artifacts lost their expectations", file=sys.stderr)
    sys.exit(1)

if expiry_checks_verified == 0:
    print("error: no expiry checks ran — the expiration artifacts lost their expectations", file=sys.stderr)
    sys.exit(1)

print(
    f"KDBX compatibility gate passed for {len(artifacts)} artifacts "
    f"({attachment_checks_verified} attachment checks, "
    f"{password_checks_verified} protected-password checks, "
    f"{totp_checks_verified} TOTP checks, "
    f"{custom_field_checks_verified} custom-field/history checks, "
    f"{expiry_checks_verified} expiry checks verified)."
)

PY
