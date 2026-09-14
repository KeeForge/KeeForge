#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${SCRIPT_DIR}/restore_pre_ui_state.swift"
FIXTURE="${REPO_ROOT}/TestFixtures/test.kdbx"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/keeforge-restore-fixture.XXXXXX")"
trap 'rm -rf -- "${TMP_ROOT}"' EXIT

expect_failure() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "error: ${name} unexpectedly passed" >&2
    exit 1
  fi
  echo "fixture=${name} result=failed-as-expected"
}

make_backup() {
  local root="$1"
  mkdir -p "${root}/app-group/databases"
  printf 'original database bytes\n' >"${root}/app-group/databases/original.kdbx"
  printf 'original registry\n' >"${root}/app-group/database-list.json"
  /usr/bin/swift "${HELPER}" write-manifest --root "${root}" --output "${root}/sha256.json" >/dev/null
}

cat >"${TMP_ROOT}/original-defaults.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>count</key><integer>42</integer><key>enabled</key><true/></dict></plist>
PLIST
cat >"${TMP_ROOT}/current-defaults.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>count</key><integer>7</integer><key>transient</key><string>remove</string></dict></plist>
PLIST

"${SCRIPT_DIR}/restore_pre_ui_state.sh" --self-test-processes
expect_failure outside-release-session-root \
  "${SCRIPT_DIR}/restore_pre_ui_state.sh" --state-root "${TMP_ROOT}/outside" --backup
expect_failure parent-traversal-state-root \
  "${SCRIPT_DIR}/restore_pre_ui_state.sh" --state-root "${REPO_ROOT}/scratch/release-session/.." --backup
expect_failure foreign-defaults-domain \
  /usr/bin/swift "${HELPER}" snapshot-defaults --domain example.invalid --output "${TMP_ROOT}/foreign.plist"

make_backup "${TMP_ROOT}/backup"
/usr/bin/swift "${HELPER}" verify-backup-manifest --root "${TMP_ROOT}/backup"

cp -R "${TMP_ROOT}/backup" "${TMP_ROOT}/missing-manifest"
rm -f -- "${TMP_ROOT}/missing-manifest/sha256.json"
expect_failure missing-original-manifest \
  /usr/bin/swift "${HELPER}" verify-backup-manifest --root "${TMP_ROOT}/missing-manifest"

cp -R "${TMP_ROOT}/backup" "${TMP_ROOT}/changed-manifest"
printf 'changed original bytes\n' >"${TMP_ROOT}/changed-manifest/app-group/database-list.json"
expect_failure changed-original-manifest \
  /usr/bin/swift "${HELPER}" verify-backup-manifest --root "${TMP_ROOT}/changed-manifest"

cp -R "${TMP_ROOT}/backup" "${TMP_ROOT}/unmanifested-backup"
printf 'unmanifested bytes\n' >"${TMP_ROOT}/unmanifested-backup/app-group/unmanifested.json"
expect_failure unmanifested-original-file \
  /usr/bin/swift "${HELPER}" verify-backup-manifest --root "${TMP_ROOT}/unmanifested-backup"

cp -R "${TMP_ROOT}/backup" "${TMP_ROOT}/symlink-backup"
ln -s database-list.json "${TMP_ROOT}/symlink-backup/app-group/linked.json"
expect_failure symlinked-original-file \
  /usr/bin/swift "${HELPER}" verify-backup-manifest --root "${TMP_ROOT}/symlink-backup"

cp -R "${TMP_ROOT}/backup/app-group" "${TMP_ROOT}/unknown-live"
printf 'unknown bytes\n' >"${TMP_ROOT}/unknown-live/unproven.kdbx"
expect_failure unknown-live-extra \
  /usr/bin/swift "${HELPER}" remove-proven-fixture-extra \
  --backup "${TMP_ROOT}/backup/app-group" --live "${TMP_ROOT}/unknown-live" --fixture "${FIXTURE}"

cp -R "${TMP_ROOT}/backup/app-group" "${TMP_ROOT}/symlink-live"
ln -s database-list.json "${TMP_ROOT}/symlink-live/linked.json"
expect_failure symlinked-live-file \
  /usr/bin/swift "${HELPER}" validate-group --group "${TMP_ROOT}/symlink-live"

cp -R "${TMP_ROOT}/backup/app-group" "${TMP_ROOT}/fixture-live"
rm -f -- "${TMP_ROOT}/fixture-live/databases/original.kdbx"
cp "${FIXTURE}" "${TMP_ROOT}/fixture-live/databases/test.kdbx"
/usr/bin/swift "${HELPER}" remove-proven-fixture-extra \
  --backup "${TMP_ROOT}/backup/app-group" --live "${TMP_ROOT}/fixture-live" --fixture "${FIXTURE}"
/usr/bin/swift "${HELPER}" compare-groups \
  --backup "${TMP_ROOT}/backup/app-group" --live "${TMP_ROOT}/fixture-live" | grep -Fq 'live_extra=0 backup_missing=1'
/usr/bin/rsync -a --checksum "${TMP_ROOT}/backup/app-group/" "${TMP_ROOT}/fixture-live/"
/usr/bin/swift "${HELPER}" verify-restored-group \
  --root "${TMP_ROOT}/backup" --group "${TMP_ROOT}/fixture-live"
/usr/bin/swift "${HELPER}" compare-groups \
  --backup "${TMP_ROOT}/backup/app-group" --live "${TMP_ROOT}/fixture-live" | grep -Fq 'live_extra=0 backup_missing=0'
echo 'fixture=proven-cache-and-original-restore result=passed'

/usr/bin/swift "${HELPER}" restore-defaults-file \
  --original "${TMP_ROOT}/original-defaults.plist" \
  --current "${TMP_ROOT}/current-defaults.plist" \
  --output "${TMP_ROOT}/restored-defaults.plist"
/usr/bin/swift "${HELPER}" verify-defaults-file \
  --expected "${TMP_ROOT}/original-defaults.plist" --actual "${TMP_ROOT}/restored-defaults.plist"
echo 'fixture=defaults-semantic-restore result=passed'
echo 'restore-pre-ui-state fixtures passed'
