#!/usr/bin/env bash
#
# Regenerates the KeePass Synchronize merge oracle fixtures under TestFixtures/Merge/.
#
# Each scenario is a trio of KDBX 4 databases sharing one password:
#
#   local.kdbx             the side KeeForge holds in memory (merge target)
#   remote.kdbx            the side that landed on disk / in the cloud (merge source)
#   merged-reference.kdbx  cp local.kdbx + `keepassxc-cli merge -s <target> <source>`
#
# Real KeePassXC is the behavioural oracle for KeeForge's own merge engine. Read
# TestFixtures/README.md ("Merge Fixtures") for the oracle's known limitation: the CLI
# runs the merge in KeePassXC's KeepNewer mode, which never applies DeletedObjects
# tombstones. Delete scenarios are still generated; their manifest entries record where
# the reference and the Synchronize semantics KeeForge implements diverge.
#
# The base database is built with pykeepass, not `keepassxc-cli db-create`: db-create
# only writes KDBX 3.1, and KeeForge's writer is KDBX 4 only. Every subsequent edit goes
# through keepassxc-cli, which preserves the KDBX 4 format of the file it opens.
#
# Usage:
#   scripts/generate-merge-fixtures.sh [--output DIR] [--keepassxc-cli PATH]
#                                      [--scenario ID]... [--list]
#
# Requirements: python3 with pykeepass (pip3 install --user pykeepass) and KeePassXC's
# keepassxc-cli. Generation is deliberately slow: KDBX timestamps have one-second
# granularity and merge resolution is timestamp-driven, so the script sleeps between
# edits whose ordering carries meaning.

set -euo pipefail

readonly DEFAULT_CLI="/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"

# Shared by every generated database. Mirrors the TestFixtures convention.
readonly PASSWORD="testpassword123"

# > 1s so that two consecutive edits always land in different KDBX-serialized seconds.
readonly STEP_SLEEP="1.2"

# Stable UUIDs for the base tree, so tests and the manifest can key on them.
readonly UUID_ROOT="00000000-0000-4000-8000-000000000000"
readonly UUID_GROUP_WORK="11111111-1111-4111-8111-111111111111"
readonly UUID_GROUP_PERSONAL="22222222-2222-4222-8222-222222222222"
readonly UUID_GROUP_ARCHIVE="33333333-3333-4333-8333-333333333333"
readonly UUID_ENTRY_ALPHA="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
readonly UUID_ENTRY_BETA="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
readonly UUID_ENTRY_GAMMA="cccccccc-cccc-4ccc-8ccc-cccccccccccc"

readonly SCENARIOS=(
  both-add-entries
  remote-newer-wins
  local-newer-wins
  history-union
  same-timestamp-diverged
  move-vs-edit
  move-into-remote-only-group
  delete-local-then-edit-remote
  edit-remote-then-delete-local
  delete-remote-then-edit-local
  edit-local-then-delete-remote
  recycle-vs-edit
  group-rename-vs-entry-add
  group-deleted-vs-entry-added
  attachment-divergence
  identical-no-changes
)

CLI="$DEFAULT_CLI"
OUTPUT_DIR=""
WORK=""
BASE_DB=""
SELECTED=()

log() { printf '%s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# keepassxc-cli wrappers. Every command reads the database password from stdin;
# the prompt itself goes to stderr, so stdout stays clean for capture.
# ---------------------------------------------------------------------------

kc() { printf '%s\n' "$PASSWORD" | "$CLI" "$@" 2>/dev/null; }

cli_add() { # db entry-path username entry-password
  local db="$1" path="$2" user="$3" pw="$4"
  printf '%s\n%s\n%s\n' "$PASSWORD" "$pw" "$pw" |
    "$CLI" add -q -p -u "$user" "$db" "$path" >/dev/null 2>&1
}

cli_edit_notes() { # db entry-path notes
  kc edit -q --notes "$3" "$1" "$2" >/dev/null
}

cli_edit_password() { # db entry-path new-entry-password
  printf '%s\n%s\n%s\n' "$PASSWORD" "$3" "$3" |
    "$CLI" edit -q -p "$1" "$2" >/dev/null 2>&1
}

cli_mkdir() { kc mkdir -q "$1" "$2" >/dev/null; }
cli_mv() { kc mv -q "$1" "$2" "$3" >/dev/null; }
cli_attach() { kc attachment-import -q "$1" "$2" "$3" "$4" >/dev/null; }

# `rm` / `rmdir` recycle on the first call and permanently delete (writing a
# DeletedObjects tombstone) on the second, once the object sits in the bin.
cli_recycle_entry() { kc rm -q "$1" "$2" >/dev/null; }

cli_purge_entry() { # db entry-path entry-title
  kc rm -q "$1" "$2" >/dev/null
  kc rm -q "$1" "/Recycle Bin/$3" >/dev/null
}

cli_purge_group() { # db group-path group-name
  kc rmdir -q "$1" "$2" >/dev/null
  kc rmdir -q "$1" "/Recycle Bin/$3" >/dev/null
}

pause() { sleep "$STEP_SLEEP"; }

kdbx_version() {
  python3 - "$1" <<'PY'
import struct
import sys

with open(sys.argv[1], "rb") as handle:
    header = handle.read(12)
if header[:4] != b"\x03\xd9\xa2\x9a":
    raise SystemExit("not a KDBX file: " + sys.argv[1])
minor, major = struct.unpack("<HH", header[8:12])
print(f"{major}.{minor}")
PY
}

dump_structure() { # db
  printf '%s\n' "kdbx-version: $(kdbx_version "$1")"
  kc export -q -f xml "$1" | python3 "$WORK/dump.py"
}

verify_db() { # db
  local db="$1"
  [ -s "$db" ] || die "missing or empty database: $db"
  kc db-info -q "$db" >/dev/null || die "keepassxc-cli cannot open $db"
  kc ls -R -q "$db" >/dev/null || die "keepassxc-cli cannot list $db"
  case "$(kdbx_version "$db")" in
    4.*) ;;
    *) die "$db is not KDBX 4 (got $(kdbx_version "$db"))" ;;
  esac
}

# ---------------------------------------------------------------------------
# Helper scripts written into the work directory.
# ---------------------------------------------------------------------------

write_helpers() {
  cat >"$WORK/dump.py" <<'PY'
"""Reads a `keepassxc-cli export -f xml` document on stdin, prints a stable,
human-readable structural dump: tree, timestamps, history, attachments, tombstones."""
import base64
import datetime
import struct
import sys
import xml.etree.ElementTree as ET

EPOCH = datetime.datetime(1, 1, 1)


def when(value):
    if value is None:
        return "-"
    try:
        raw = base64.b64decode(value)
    except Exception:
        return value
    if len(raw) != 8:
        return value
    seconds = struct.unpack("<q", raw)[0]
    return (EPOCH + datetime.timedelta(seconds=seconds)).isoformat() + "Z"


def uuid_hex(value):
    if value is None:
        return "-"
    raw = base64.b64decode(value)
    hex_value = raw.hex()
    return "-".join(
        [hex_value[0:8], hex_value[8:12], hex_value[12:16], hex_value[16:20], hex_value[20:32]]
    )


def fields(node):
    out = {}
    for string in node.findall("String"):
        out[string.findtext("Key")] = string.findtext("Value") or ""
    return out


def attachments(node):
    out = []
    for binary in node.findall("Binary"):
        value = binary.find("Value")
        size = "ref=" + value.get("Ref") if value is not None and value.get("Ref") else (
            "bytes=%d" % len(base64.b64decode(value.text or "")) if value is not None else "-"
        )
        out.append((binary.findtext("Key"), size))
    return out


def times(node):
    node_times = node.find("Times")
    if node_times is None:
        return "-", "-"
    return when(node_times.findtext("LastModificationTime")), when(node_times.findtext("LocationChanged"))


def dump_entry(entry, path, indent):
    values = fields(entry)
    title = values.get("Title", "")
    lmt, loc = times(entry)
    print(f"{indent}ENTRY {path}/{title} uuid={uuid_hex(entry.findtext('UUID'))} lmt={lmt} loc={loc}")
    for key in sorted(values):
        print(f"{indent}  FIELD {key}={values[key]!r}")
    for name, size in attachments(entry):
        print(f"{indent}  ATTACH {name} {size}")
    for item in entry.findall("History/Entry"):
        hist = fields(item)
        hist_lmt, _ = times(item)
        summary = ", ".join(f"{key}={hist[key]!r}" for key in sorted(hist) if hist[key] != "")
        for name, size in attachments(item):
            summary += f", attachment {name} {size}"
        print(f"{indent}  HIST lmt={hist_lmt} {summary}")


def dump_group(group, parent_path, indent):
    name = group.findtext("Name")
    path = f"{parent_path}/{name}"
    lmt, loc = times(group)
    print(f"{indent}GROUP {path} uuid={uuid_hex(group.findtext('UUID'))} lmt={lmt} loc={loc}")
    for entry in group.findall("Entry"):
        dump_entry(entry, path, indent + "  ")
    for child in group.findall("Group"):
        dump_group(child, path, indent + "  ")


root = ET.parse(sys.stdin).getroot()
meta = root.find("Meta")
if meta is not None:
    recycle_uuid = meta.findtext("RecycleBinUUID")
    print(
        "META name={!r} recycleBinEnabled={} recycleBinUUID={} historyMaxItems={}".format(
            meta.findtext("DatabaseName") or "",
            meta.findtext("RecycleBinEnabled"),
            uuid_hex(recycle_uuid) if recycle_uuid else "-",
            meta.findtext("HistoryMaxItems"),
        )
    )
for group in root.findall("Root/Group"):
    dump_group(group, "", "")
deleted = root.findall("Root/DeletedObjects/DeletedObject")
if not deleted:
    print("TOMBSTONES none")
for obj in deleted:
    print(f"TOMBSTONE uuid={uuid_hex(obj.findtext('UUID'))} deleted={when(obj.findtext('DeletionTime'))}")
PY

  cat >"$WORK/make_base.py" <<'PY'
"""Creates the shared base database (KDBX 4.0, AES-256) with deterministic UUIDs."""
import sys
import uuid

from pykeepass import create_database

path, password = sys.argv[1], sys.argv[2]
(
    root_uuid,
    work_uuid,
    personal_uuid,
    archive_uuid,
    alpha_uuid,
    beta_uuid,
    gamma_uuid,
) = sys.argv[3:10]

kp = create_database(path, password=password)
kp.root_group.uuid = uuid.UUID(root_uuid)

work = kp.add_group(kp.root_group, "Work")
work.uuid = uuid.UUID(work_uuid)
alpha = kp.add_entry(work, "Alpha", "alpha-user", "AlphaSecret1", url="https://alpha.example.com")
alpha.uuid = uuid.UUID(alpha_uuid)
beta = kp.add_entry(work, "Beta", "beta-user", "BetaSecret2", url="https://beta.example.com")
beta.uuid = uuid.UUID(beta_uuid)

personal = kp.add_group(kp.root_group, "Personal")
personal.uuid = uuid.UUID(personal_uuid)
gamma = kp.add_entry(personal, "Gamma", "gamma-user", "GammaSecret3", notes="base notes")
gamma.uuid = uuid.UUID(gamma_uuid)

archive = kp.add_group(kp.root_group, "Archive")
archive.uuid = uuid.UUID(archive_uuid)

kp.save()
PY

  cat >"$WORK/set_group_name.py" <<'PY'
"""Renames a group and stamps its LastModificationTime to now (UTC).

keepassxc-cli has no group-rename command, so an independent implementation does it."""
import datetime
import sys

from pykeepass import PyKeePass

path, password, old_name, new_name = sys.argv[1:5]
kp = PyKeePass(path, password=password)
group = kp.find_groups(name=old_name, first=True)
if group is None:
    raise SystemExit(f"group not found: {old_name}")
group.name = new_name
group.mtime = datetime.datetime.now(datetime.timezone.utc)
kp.save()
PY

  cat >"$WORK/set_entry_password_at.py" <<'PY'
"""Sets an entry's password and forces an exact LastModificationTime.

Used to build the equal-timestamp/different-content case, which cannot be produced
reliably by racing two keepassxc-cli edits inside the same wall-clock second."""
import datetime
import sys

from pykeepass import PyKeePass

path, password, title, new_value, epoch_seconds = sys.argv[1:6]
kp = PyKeePass(path, password=password)
entry = kp.find_entries(title=title, first=True)
if entry is None:
    raise SystemExit(f"entry not found: {title}")
entry.password = new_value
entry.mtime = datetime.datetime.fromtimestamp(int(epoch_seconds), datetime.timezone.utc)
kp.save()
PY

  printf 'merge fixture attachment payload\n' >"$WORK/attachment.txt"
}

# ---------------------------------------------------------------------------
# Scenarios. Each receives the scenario directory and mutates local.kdbx /
# remote.kdbx in place. Ordering of edits is deliberate: `pause` between two
# edits whose relative timestamp decides the merge outcome.
# ---------------------------------------------------------------------------

scenario_both_add_entries() {
  local dir="$1"
  cli_add "$dir/local.kdbx" "/Work/Local Only" "local-only-user" "LocalOnlySecret1"
  cli_add "$dir/remote.kdbx" "/Personal/Remote Only" "remote-only-user" "RemoteOnlySecret2"
}

scenario_remote_newer_wins() {
  local dir="$1"
  cli_edit_notes "$dir/local.kdbx" "/Work/Alpha" "local edit (loser)"
  pause
  cli_edit_notes "$dir/remote.kdbx" "/Work/Alpha" "remote edit (winner)"
}

scenario_local_newer_wins() {
  local dir="$1"
  cli_edit_notes "$dir/remote.kdbx" "/Work/Alpha" "remote edit (loser)"
  pause
  cli_edit_notes "$dir/local.kdbx" "/Work/Alpha" "local edit (winner)"
}

scenario_history_union() {
  local dir="$1"
  cli_edit_notes "$dir/local.kdbx" "/Work/Alpha" "local edit 1"
  pause
  cli_edit_notes "$dir/remote.kdbx" "/Work/Alpha" "remote edit 1"
  pause
  cli_edit_notes "$dir/local.kdbx" "/Work/Alpha" "local edit 2"
  pause
  cli_edit_notes "$dir/remote.kdbx" "/Work/Alpha" "remote edit 2"
}

scenario_same_timestamp_diverged() {
  local dir="$1"
  local stamp
  stamp="$(date +%s)"
  python3 "$WORK/set_entry_password_at.py" \
    "$dir/local.kdbx" "$PASSWORD" "Alpha" "LocalSameSecond" "$stamp"
  python3 "$WORK/set_entry_password_at.py" \
    "$dir/remote.kdbx" "$PASSWORD" "Alpha" "RemoteSameSecond" "$stamp"
}

scenario_move_vs_edit() {
  local dir="$1"
  cli_mv "$dir/remote.kdbx" "/Work/Alpha" "/Archive"
  pause
  cli_edit_password "$dir/local.kdbx" "/Work/Alpha" "AlphaEditedLocally9"
}

scenario_move_into_remote_only_group() {
  local dir="$1"
  cli_mkdir "$dir/remote.kdbx" "/Remote Vault"
  cli_mv "$dir/remote.kdbx" "/Work/Beta" "/Remote Vault"
  pause
  cli_edit_notes "$dir/local.kdbx" "/Work/Beta" "local edit while remote moved it"
}

scenario_delete_local_then_edit_remote() {
  local dir="$1"
  cli_purge_entry "$dir/local.kdbx" "/Work/Alpha" "Alpha"
  pause
  cli_edit_notes "$dir/remote.kdbx" "/Work/Alpha" "remote edit after local deletion"
}

scenario_edit_remote_then_delete_local() {
  local dir="$1"
  cli_edit_notes "$dir/remote.kdbx" "/Work/Alpha" "remote edit before local deletion"
  pause
  cli_purge_entry "$dir/local.kdbx" "/Work/Alpha" "Alpha"
}

scenario_delete_remote_then_edit_local() {
  local dir="$1"
  cli_purge_entry "$dir/remote.kdbx" "/Work/Alpha" "Alpha"
  pause
  cli_edit_notes "$dir/local.kdbx" "/Work/Alpha" "local edit after remote deletion"
}

scenario_edit_local_then_delete_remote() {
  local dir="$1"
  cli_edit_notes "$dir/local.kdbx" "/Work/Alpha" "local edit before remote deletion"
  pause
  cli_purge_entry "$dir/remote.kdbx" "/Work/Alpha" "Alpha"
}

scenario_recycle_vs_edit() {
  local dir="$1"
  cli_recycle_entry "$dir/remote.kdbx" "/Work/Beta"
  pause
  cli_edit_notes "$dir/local.kdbx" "/Work/Beta" "local edit after remote recycled it"
}

scenario_group_rename_vs_entry_add() {
  local dir="$1"
  cli_add "$dir/local.kdbx" "/Work/Late Addition" "late-user" "LateSecret4"
  pause
  python3 "$WORK/set_group_name.py" "$dir/remote.kdbx" "$PASSWORD" "Work" "Work Renamed"
}

scenario_group_deleted_vs_entry_added() {
  local dir="$1"
  cli_purge_group "$dir/remote.kdbx" "/Archive" "Archive"
  pause
  cli_add "$dir/local.kdbx" "/Archive/Kept Entry" "kept-user" "KeptSecret5"
}

scenario_attachment_divergence() {
  local dir="$1"
  cli_attach "$dir/remote.kdbx" "/Personal/Gamma" "merge-note.txt" "$WORK/attachment.txt"
  pause
  cli_edit_notes "$dir/local.kdbx" "/Personal/Gamma" "local edit, no attachment"
}

scenario_identical_no_changes() {
  : # local.kdbx and remote.kdbx stay byte-identical copies of the base database.
}

scenario_function_for() {
  printf 'scenario_%s' "${1//-/_}"
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

build_scenario() {
  local id="$1"
  local dir="$OUTPUT_DIR/$id"
  local fn merge_out remerge_out

  fn="$(scenario_function_for "$id")"
  log "==> $id"

  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$BASE_DB" "$dir/local.kdbx"
  cp "$BASE_DB" "$dir/remote.kdbx"

  "$fn" "$dir"

  verify_db "$dir/local.kdbx"
  verify_db "$dir/remote.kdbx"

  # Run the merges from inside the scenario directory so the recorded output carries
  # relative file names instead of this machine's absolute paths.
  cp "$dir/local.kdbx" "$dir/merged-reference.kdbx"
  merge_out="$(cd "$dir" && printf '%s\n' "$PASSWORD" |
    "$CLI" merge -s merged-reference.kdbx remote.kdbx 2>/dev/null)"
  verify_db "$dir/merged-reference.kdbx"

  # Idempotence: re-merging the same source into the reference must be a no-op.
  cp "$dir/merged-reference.kdbx" "$dir/remerge.kdbx"
  remerge_out="$(cd "$dir" && printf '%s\n' "$PASSWORD" |
    "$CLI" merge -s remerge.kdbx remote.kdbx 2>/dev/null)"
  remerge_out="${remerge_out//remerge.kdbx/merged-reference.kdbx}"
  rm -f "$dir/remerge.kdbx"

  {
    printf '# scenario: %s\n' "$id"
    printf '# password: %s\n' "$PASSWORD"
    printf '# generated by scripts/generate-merge-fixtures.sh with %s\n' "$("$CLI" --version)"
    printf '# merge direction: remote.kdbx (source) merged INTO a copy of local.kdbx (target)\n'
    printf '# note: when the source entry wins, KeePassXC erases the target entry and appends a\n'
    printf '#       clone, so the winner moves to the END of its group. Sibling order in the\n'
    printf '#       reference is not normative - compare merged trees order-insensitively.\n'
    printf '\n## keepassxc-cli merge output\n%s\n' "$merge_out"
    printf '\n## keepassxc-cli merge output, re-run against merged-reference.kdbx (idempotence)\n%s\n' "$remerge_out"
    printf '\n## local.kdbx: ls -R\n'
    kc ls -R -q "$dir/local.kdbx"
    printf '\n## remote.kdbx: ls -R\n'
    kc ls -R -q "$dir/remote.kdbx"
    printf '\n## merged-reference.kdbx: ls -R\n'
    kc ls -R -q "$dir/merged-reference.kdbx"
    printf '\n## local.kdbx: structure\n'
    dump_structure "$dir/local.kdbx"
    printf '\n## remote.kdbx: structure\n'
    dump_structure "$dir/remote.kdbx"
    printf '\n## merged-reference.kdbx: structure\n'
    dump_structure "$dir/merged-reference.kdbx"
  } >"$dir/expectations.txt"

  case "$remerge_out" in
    *"not modified by merge"*) ;;
    *) log "    warning: re-merge reported changes (not idempotent): $remerge_out" ;;
  esac
}

write_manifest() {
  python3 - "$OUTPUT_DIR/manifest.json" "$PASSWORD" "$("$CLI" --version)" <<'PY'
import json
import sys

out_path, password, cli_version = sys.argv[1:4]

KEEP_NEWER_NOTE = (
    "keepassxc-cli runs Merger in KeePassXC's KeepNewer mode (the root group's merge mode "
    "falls back to KeepNewer and Merger::mergeDeletions returns early for every mode except "
    "Synchronize), so the reference never applies DeletedObjects tombstones."
)

scenarios = [
    {
        "id": "both-add-entries",
        "description": "Local adds an entry to Work, remote adds a different entry to Personal.",
        "editOrder": ["local: add /Work/Local Only", "remote: add /Personal/Remote Only"],
        "assertions": [
            "merged tree contains /Work/Local Only (username local-only-user)",
            "merged tree contains /Personal/Remote Only (username remote-only-user)",
            "no entry is dropped and neither addition gains history",
        ],
        "oracleMatchesSpec": True,
    },
    {
        "id": "remote-newer-wins",
        "description": "Both sides edit Alpha's notes; the remote edit is newer.",
        "editOrder": [
            "local: edit /Work/Alpha notes = 'local edit (loser)'",
            "sleep >1s",
            "remote: edit /Work/Alpha notes = 'remote edit (winner)'",
        ],
        "assertions": [
            "current /Work/Alpha carries the remote notes",
            "the losing local version appears as a history item of the merged entry",
            "the pre-split base version also survives in history",
        ],
        "oracleMatchesSpec": True,
    },
    {
        "id": "local-newer-wins",
        "description": "Both sides edit Alpha's notes; the local edit is newer.",
        "editOrder": [
            "remote: edit /Work/Alpha notes = 'remote edit (loser)'",
            "sleep >1s",
            "local: edit /Work/Alpha notes = 'local edit (winner)'",
        ],
        "assertions": [
            "current /Work/Alpha keeps the local notes",
            "the losing remote version appears as a history item of the merged entry",
        ],
        "oracleMatchesSpec": True,
    },
    {
        "id": "history-union",
        "description": "Interleaved edits give each side its own pre-existing history list.",
        "editOrder": [
            "local: edit notes = 'local edit 1'",
            "remote: edit notes = 'remote edit 1'",
            "local: edit notes = 'local edit 2'",
            "remote: edit notes = 'remote edit 2'",
        ],
        "assertions": [
            "current /Work/Alpha carries 'remote edit 2' (newest LastModificationTime)",
            "history is the union of both sides keyed by LastModificationTime: base, "
            "'local edit 1', 'remote edit 1', 'local edit 2'",
            "history items are ordered chronologically and never duplicated",
        ],
        "oracleMatchesSpec": True,
    },
    {
        "id": "same-timestamp-diverged",
        "description": (
            "Alpha's password differs across the pair while both sides carry the exact same "
            "LastModificationTime (forced with pykeepass; two keepassxc-cli edits cannot be "
            "raced into one second reliably)."
        ),
        "editOrder": [
            "local: password = LocalSameSecond at T",
            "remote: password = RemoteSameSecond at the same T",
        ],
        "assertions": [
            "equal timestamps are treated as the same version: the merged entry keeps the "
            "local (target) password and no history item is pushed",
        ],
        "oracleMatchesSpec": True,
    },
    {
        "id": "move-vs-edit",
        "description": "Remote moves Alpha to Archive, local then edits Alpha's password.",
        "editOrder": [
            "remote: mv /Work/Alpha -> /Archive",
            "sleep >1s",
            "local: edit /Work/Alpha password = AlphaEditedLocally9",
        ],
        "assertions": [
            "merged Alpha lives in /Archive (remote's LocationChanged is newer)",
            "merged Alpha keeps the locally edited password (local LastModificationTime is newer)",
            "both effects survive; the move is not undone by the content merge",
        ],
        "oracleMatchesSpec": True,
        "oracleLimitation": (
            "The reference moves Alpha but leaves its LocationChanged at the stale local value. "
            "KeeForge adopts the source LocationChanged per the spec, so compare placement, not "
            "the LocationChanged timestamp, against this reference."
        ),
    },
    {
        "id": "move-into-remote-only-group",
        "description": "Remote creates /Remote Vault and moves Beta into it; local edits Beta.",
        "editOrder": [
            "remote: mkdir /Remote Vault; mv /Work/Beta -> /Remote Vault",
            "sleep >1s",
            "local: edit /Work/Beta notes",
        ],
        "assertions": [
            "/Remote Vault is created in the merged tree",
            "Beta lives inside /Remote Vault and carries the local notes edit",
        ],
        "oracleMatchesSpec": True,
        "oracleLimitation": (
            "A newly created group DOES adopt the source LocationChanged; the moved entry does "
            "not. Beta's LocationChanged in the reference is the stale local value."
        ),
    },
    {
        "id": "delete-local-then-edit-remote",
        "description": (
            "Local permanently deletes Alpha (tombstone on the target side); remote edits it "
            "afterwards. Edit-after-delete resurrection."
        ),
        "editOrder": [
            "local: rm /Work/Alpha, then rm '/Recycle Bin/Alpha' (permanent, writes tombstone)",
            "sleep >1s",
            "remote: edit /Work/Alpha notes",
        ],
        "assertions": [
            "Alpha is resurrected into /Work with the remote notes edit",
            "resurrection is required because the remote LastModificationTime is later than "
            "the local DeletionTime",
        ],
        "specNote": (
            "KeeForge (Synchronize semantics) must additionally DROP the local tombstone on "
            "resurrection. The reference keeps it: the CLI never runs the deletion pass, so "
            "the target's own tombstone is carried over untouched alongside the live entry."
        ),
        "oracleMatchesSpec": False,
        "oracleLimitation": KEEP_NEWER_NOTE,
    },
    {
        "id": "edit-remote-then-delete-local",
        "description": (
            "Remote edits Alpha first; local permanently deletes it afterwards. "
            "Delete-after-edit."
        ),
        "editOrder": [
            "remote: edit /Work/Alpha notes",
            "sleep >1s",
            "local: rm /Work/Alpha, then rm '/Recycle Bin/Alpha' (permanent, writes tombstone)",
        ],
        "assertions": [
            "spec: Alpha stays deleted (its LastModificationTime precedes the DeletionTime) "
            "and the tombstone survives so the deletion propagates to third replicas",
        ],
        "specNote": (
            "The reference DISAGREES with the spec: it re-adds Alpha from the remote side and "
            "keeps the local tombstone, leaving a live entry and a tombstone with the same "
            "UUID. KeeForge must delete instead."
        ),
        "oracleMatchesSpec": False,
        "oracleLimitation": KEEP_NEWER_NOTE,
    },
    {
        "id": "delete-remote-then-edit-local",
        "description": (
            "Remote permanently deletes Alpha (tombstone on the source side); local edits it "
            "afterwards. Edit-after-delete resurrection, mirrored direction."
        ),
        "editOrder": [
            "remote: rm /Work/Alpha, then rm '/Recycle Bin/Alpha' (permanent, writes tombstone)",
            "sleep >1s",
            "local: edit /Work/Alpha notes",
        ],
        "assertions": [
            "Alpha survives in /Work with the local notes edit",
            "the remote tombstone is dropped from the merged DeletedObjects list",
        ],
        "oracleMatchesSpec": True,
        "oracleLimitation": (
            "The reference reaches the spec's outcome for the wrong reason: it never unions "
            "the source tombstone at all. " + KEEP_NEWER_NOTE
        ),
    },
    {
        "id": "edit-local-then-delete-remote",
        "description": (
            "Local edits Alpha first; remote permanently deletes it afterwards. "
            "Delete-after-edit, mirrored direction."
        ),
        "editOrder": [
            "local: edit /Work/Alpha notes",
            "sleep >1s",
            "remote: rm /Work/Alpha, then rm '/Recycle Bin/Alpha' (permanent, writes tombstone)",
        ],
        "assertions": [
            "spec: Alpha is deleted from the merged tree and the remote tombstone is kept",
        ],
        "specNote": (
            "The reference DISAGREES with the spec: Alpha survives with the local edit and the "
            "remote tombstone is discarded. This is the clearest demonstration that the CLI "
            "reference cannot be used as the oracle for deletion propagation."
        ),
        "oracleMatchesSpec": False,
        "oracleLimitation": KEEP_NEWER_NOTE,
    },
    {
        "id": "recycle-vs-edit",
        "description": (
            "Remote recycles Beta (a move into a newly created Recycle Bin); local edits Beta "
            "afterwards."
        ),
        "editOrder": [
            "remote: rm /Work/Beta (recycles, creating the bin)",
            "sleep >1s",
            "local: edit /Work/Beta notes",
        ],
        "assertions": [
            "the merged tree contains the remote's Recycle Bin group",
            "Beta lives inside the Recycle Bin (recycling is a move, gated on LocationChanged)",
            "Beta carries the local notes edit (newer LastModificationTime)",
            "spec: the merged Meta adopts the remote's RecycleBinUUID (local had no bin)",
        ],
        "specNote": (
            "The reference does NOT adopt RecycleBinUUID: the bin group is present in the tree "
            "while Meta/RecycleBinUUID stays all-zero, so a later deletion in KeePassXC would "
            "create a second bin. KeeForge adopts it per the spec."
        ),
        "oracleMatchesSpec": False,
        "oracleLimitation": (
            "Merger::mergeMetadata carries an explicit TODO for recycle-bin handling and merges "
            "only custom icons and custom data."
        ),
    },
    {
        "id": "group-rename-vs-entry-add",
        "description": "Local adds an entry to Work; remote then renames Work to 'Work Renamed'.",
        "editOrder": [
            "local: add /Work/Late Addition",
            "sleep >1s",
            "remote: rename group Work -> 'Work Renamed' with a fresh LastModificationTime",
        ],
        "assertions": [
            "the merged group is named 'Work Renamed' (newer group LastModificationTime wins)",
            "the group still contains Alpha, Beta and the locally added 'Late Addition'",
            "a rename is not a move: LocationChanged is untouched",
        ],
        "oracleMatchesSpec": True,
    },
    {
        "id": "group-deleted-vs-entry-added",
        "description": (
            "Remote permanently deletes the empty Archive group; local then adds an entry "
            "inside it."
        ),
        "editOrder": [
            "remote: rmdir /Archive, then rmdir '/Recycle Bin/Archive' (permanent, tombstones)",
            "sleep >1s",
            "local: add /Archive/Kept Entry",
        ],
        "assertions": [
            "the Archive group survives because it holds live content after the merge",
            "'Kept Entry' survives inside it",
            "the group tombstone is not applied and not carried into merged DeletedObjects",
        ],
        "oracleMatchesSpec": True,
        "oracleLimitation": (
            "Group deletion cascade is only partially exercised: the CLI reference never runs "
            "the deletion pass. " + KEEP_NEWER_NOTE
        ),
    },
    {
        "id": "attachment-divergence",
        "description": (
            "Remote attaches merge-note.txt to Gamma; local only edits Gamma's notes. The "
            "KDBX4 inner-header binary pools diverge."
        ),
        "editOrder": [
            "remote: attachment-import merge-note.txt onto /Personal/Gamma",
            "sleep >1s",
            "local: edit /Personal/Gamma notes",
        ],
        "assertions": [
            "KeeForge must DECLINE this merge: the binary pools differ and an entry references "
            "an attachment, so grafted references could dangle",
            "the merged reference is generated for completeness only and is not an expected "
            "KeeForge output",
        ],
        "oracleLimitation": (
            "In the reference the local edit is newer, so the attachment-carrying remote version "
            "lands in history: the merged file keeps a binary in its pool that only a history "
            "item references. That is exactly the dangling-reference risk KeeForge declines on."
        ),
        "oracleMatchesSpec": True,
    },
    {
        "id": "identical-no-changes",
        "description": "local.kdbx and remote.kdbx are byte-identical copies of the base database.",
        "editOrder": [],
        "assertions": [
            "keepassxc-cli reports 'Database was not modified by merge operation.'",
            "merged-reference.kdbx is byte-identical to local.kdbx",
            "KeeForge's merge must be a no-op and must not mark the database dirty",
        ],
        "oracleMatchesSpec": True,
    },
]

for scenario in scenarios:
    scenario["files"] = {
        "local": f"{scenario['id']}/local.kdbx",
        "remote": f"{scenario['id']}/remote.kdbx",
        "mergedReference": f"{scenario['id']}/merged-reference.kdbx",
        "expectations": f"{scenario['id']}/expectations.txt",
    }

manifest = {
    "generator": "scripts/generate-merge-fixtures.sh",
    "oracle": cli_version.strip(),
    "password": password,
    "kdbxVersion": "4.x (base created as 4.0 by pykeepass; keepassxc-cli may raise the minor version)",
    "mergeCommand": "keepassxc-cli merge -s <copy of local.kdbx> <remote.kdbx>",
    "mergeDirection": "remote.kdbx is the merge source, local.kdbx the merge target",
    "oracleLimitation": KEEP_NEWER_NOTE,
    "oracleNotes": [
        KEEP_NEWER_NOTE,
        "When the source entry wins a conflict, Merger erases the target entry and appends a "
        "clone of the source, so the winner ends up LAST in its group. Sibling order in a "
        "merged reference is an artefact, not a requirement - compare trees order-insensitively.",
        "Merger::eraseEntry/eraseGroup restore the DeletedObjects list after deleting, so an "
        "entry replaced during conflict resolution never gains a tombstone.",
        "keepassxc-cli `rm` (and `rmdir`) recycles on the first call and permanently deletes, "
        "writing a DeletedObjects tombstone, on the second call from inside the Recycle Bin.",
        "Entry conflict resolution and history union ignore the merge mode entirely "
        "(Merger::mergeHistory does Q_UNUSED(mergeMethod)), so everything except deletion "
        "propagation is a faithful oracle for the Synchronize semantics KeeForge implements.",
        "Merger reparents an entry when the source LocationChanged is newer but does NOT adopt "
        "that LocationChanged value (it only does so for groups), so a merge-moved entry keeps "
        "its stale local LocationChanged in the reference. KeeForge adopting the source value "
        "per the spec is a deliberate, safe divergence.",
        "Merger never adopts Meta/RecycleBinUUID (there is an explicit TODO in "
        "Merger::mergeMetadata), so a reference that gained the source's Recycle Bin group "
        "still reports the all-zero RecycleBinUUID. KeeForge adopting it per the spec is a "
        "deliberate divergence.",
    ],
    "baseTree": {
        "rootGroup": {"uuid": "00000000-0000-4000-8000-000000000000"},
        "groups": {
            "Work": "11111111-1111-4111-8111-111111111111",
            "Personal": "22222222-2222-4222-8222-222222222222",
            "Archive": "33333333-3333-4333-8333-333333333333",
        },
        "entries": {
            "/Work/Alpha": {
                "uuid": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                "username": "alpha-user",
                "password": "AlphaSecret1",
                "url": "https://alpha.example.com",
            },
            "/Work/Beta": {
                "uuid": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "username": "beta-user",
                "password": "BetaSecret2",
                "url": "https://beta.example.com",
            },
            "/Personal/Gamma": {
                "uuid": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                "username": "gamma-user",
                "password": "GammaSecret3",
                "notes": "base notes",
            },
        },
    },
    "scenarios": scenarios,
}

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, ensure_ascii=False)
    handle.write("\n")
PY
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --keepassxc-cli)
        [ $# -ge 2 ] || die "--keepassxc-cli needs a path"
        CLI="$2"
        shift 2
        ;;
      --output)
        [ $# -ge 2 ] || die "--output needs a directory"
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --scenario)
        [ $# -ge 2 ] || die "--scenario needs an id"
        SELECTED+=("$2")
        shift 2
        ;;
      --list)
        printf '%s\n' "${SCENARIOS[@]}"
        exit 0
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"

  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  [ -n "$OUTPUT_DIR" ] || OUTPUT_DIR="$repo_root/TestFixtures/Merge"

  [ -x "$CLI" ] || die "keepassxc-cli not found or not executable: $CLI"
  command -v python3 >/dev/null || die "python3 is required"
  python3 -c 'import pykeepass' 2>/dev/null || die "python3 module pykeepass is required (pip3 install --user pykeepass)"

  if [ ${#SELECTED[@]} -eq 0 ]; then
    SELECTED=("${SCENARIOS[@]}")
  fi

  WORK="$(mktemp -d)"
  # shellcheck disable=SC2064 # WORK is fixed by the time the trap fires.
  trap "rm -rf '$WORK'" EXIT

  write_helpers

  BASE_DB="$WORK/base.kdbx"
  python3 "$WORK/make_base.py" "$BASE_DB" "$PASSWORD" \
    "$UUID_ROOT" "$UUID_GROUP_WORK" "$UUID_GROUP_PERSONAL" "$UUID_GROUP_ARCHIVE" \
    "$UUID_ENTRY_ALPHA" "$UUID_ENTRY_BETA" "$UUID_ENTRY_GAMMA"
  verify_db "$BASE_DB"
  log "base database: KDBX $(kdbx_version "$BASE_DB")"

  mkdir -p "$OUTPUT_DIR"
  local id
  for id in "${SELECTED[@]}"; do
    case " ${SCENARIOS[*]} " in
      *" $id "*) ;;
      *) die "unknown scenario: $id" ;;
    esac
    build_scenario "$id"
  done

  write_manifest
  log "wrote $OUTPUT_DIR/manifest.json"
  log "done: ${#SELECTED[@]} scenario(s) in $OUTPUT_DIR"
}

main "$@"
