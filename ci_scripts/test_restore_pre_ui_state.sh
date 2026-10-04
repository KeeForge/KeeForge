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

expect_failure_message() {
  local name="$1" expected="$2" status
  shift 2
  if "$@" >"${TMP_ROOT}/refusal.out" 2>&1; then
    echo "error: ${name} unexpectedly passed" >&2
    exit 1
  else
    status=$?
  fi
  [[ "${status}" == 1 ]] && grep -Fq "${expected}" "${TMP_ROOT}/refusal.out" || {
    echo "error: ${name} failed outside its intended guard (exit=${status})" >&2
    cat "${TMP_ROOT}/refusal.out" >&2
    exit 1
  }
  echo "fixture=${name} result=failed-as-expected"
}

make_backup() {
  local root="$1"
  mkdir -p "${root}/app-group/databases" "${root}/app-group/Library/Application Scripts"
  printf 'original database bytes\n' >"${root}/app-group/databases/original.kdbx"
  printf 'original registry\n' >"${root}/app-group/database-list.json"
  ln -s '../../../../Application Scripts/group.com.keevault.shared' \
    "${root}/app-group/Library/Application Scripts/group.com.keevault.shared"
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
PATH_REPO="${TMP_ROOT}/path-repo"
mkdir -p "${PATH_REPO}/ci_scripts" "${PATH_REPO}/scratch/release-session"
cp "${SCRIPT_DIR}/restore_pre_ui_state.sh" "${PATH_REPO}/ci_scripts/restore_pre_ui_state.sh"
expect_failure_message outside-release-session-root 'state root must be directly under' \
  "${PATH_REPO}/ci_scripts/restore_pre_ui_state.sh" --state-root "${TMP_ROOT}/outside" --backup
expect_failure_message parent-traversal-state-root 'state root must name a directory under' \
  "${PATH_REPO}/ci_scripts/restore_pre_ui_state.sh" --state-root "${PATH_REPO}/scratch/release-session/.." --backup
expect_failure foreign-defaults-domain \
  /usr/bin/swift "${HELPER}" snapshot-defaults --domain example.invalid --output "${TMP_ROOT}/foreign.plist"

make_backup "${TMP_ROOT}/backup"
/usr/bin/swift "${HELPER}" verify-backup-manifest --root "${TMP_ROOT}/backup"
/usr/bin/swift "${HELPER}" validate-group --group "${TMP_ROOT}/backup/app-group" | grep -Fq 'links=1'
echo 'fixture=known-application-scripts-link result=passed'

mkdir -p "${TMP_ROOT}/empty-link-baseline/app-group/databases"
printf 'baseline without scripts link\n' >"${TMP_ROOT}/empty-link-baseline/app-group/databases/original.kdbx"
/usr/bin/swift "${HELPER}" write-manifest \
  --root "${TMP_ROOT}/empty-link-baseline" \
  --output "${TMP_ROOT}/empty-link-baseline/sha256.json" >/dev/null
/usr/bin/swift "${HELPER}" verify-backup-manifest --root "${TMP_ROOT}/empty-link-baseline"
/usr/bin/swift "${HELPER}" validate-group --group "${TMP_ROOT}/empty-link-baseline/app-group" | grep -Fq 'links=0'
echo 'fixture=empty-application-scripts-link-baseline result=passed'

cp -R "${TMP_ROOT}/backup" "${TMP_ROOT}/missing-link"
rm "${TMP_ROOT}/missing-link/app-group/Library/Application Scripts/group.com.keevault.shared"
expect_failure missing-application-scripts-link \
  /usr/bin/swift "${HELPER}" verify-backup-manifest --root "${TMP_ROOT}/missing-link"

cp -R "${TMP_ROOT}/backup" "${TMP_ROOT}/altered-link"
rm "${TMP_ROOT}/altered-link/app-group/Library/Application Scripts/group.com.keevault.shared"
ln -s '../../../../Application Scripts/other-group' \
  "${TMP_ROOT}/altered-link/app-group/Library/Application Scripts/group.com.keevault.shared"
expect_failure altered-application-scripts-link \
  /usr/bin/swift "${HELPER}" verify-backup-manifest --root "${TMP_ROOT}/altered-link"

cp -R "${TMP_ROOT}/backup" "${TMP_ROOT}/escaping-link"
ln -s '../../../../../outside-app-group' \
  "${TMP_ROOT}/escaping-link/app-group/Library/Application Scripts/escaped-link"
expect_failure escaping-application-scripts-link \
  /usr/bin/swift "${HELPER}" verify-backup-manifest --root "${TMP_ROOT}/escaping-link"

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
rm "${TMP_ROOT}/fixture-live/Library/Application Scripts/group.com.keevault.shared"
/usr/bin/rsync -a --checksum "${TMP_ROOT}/backup/app-group/" "${TMP_ROOT}/fixture-live/"
/usr/bin/swift "${HELPER}" verify-restored-group \
  --root "${TMP_ROOT}/backup" --group "${TMP_ROOT}/fixture-live"
/usr/bin/swift "${HELPER}" compare-groups \
  --backup "${TMP_ROOT}/backup/app-group" --live "${TMP_ROOT}/fixture-live" | grep -Fq 'live_extra=0 backup_missing=0'
echo 'fixture=proven-cache-and-original-restore result=passed'

cp -R "${TMP_ROOT}/backup/app-group" "${TMP_ROOT}/fixture-extra-only"
cp "${FIXTURE}" "${TMP_ROOT}/fixture-extra-only/databases/test.kdbx"
/usr/bin/swift "${HELPER}" remove-proven-fixture-extra \
  --backup "${TMP_ROOT}/backup/app-group" --live "${TMP_ROOT}/fixture-extra-only" --fixture "${FIXTURE}"
/usr/bin/swift "${HELPER}" verify-restored-group \
  --root "${TMP_ROOT}/backup" --group "${TMP_ROOT}/fixture-extra-only"
/usr/bin/swift "${HELPER}" compare-groups \
  --backup "${TMP_ROOT}/backup/app-group" --live "${TMP_ROOT}/fixture-extra-only" | grep -Fq 'live_extra=0 backup_missing=0'
echo 'fixture=proven-cache-with-originals-intact result=passed'

cp -R "${TMP_ROOT}/backup/app-group" "${TMP_ROOT}/unknown-cache-extra"
printf 'unknown database bytes\n' >"${TMP_ROOT}/unknown-cache-extra/databases/unknown.kdbx"
expect_failure_message unknown-cache-extra 'restore-helper failed: verificationFailed' \
  /usr/bin/swift "${HELPER}" remove-proven-fixture-extra \
  --backup "${TMP_ROOT}/backup/app-group" --live "${TMP_ROOT}/unknown-cache-extra" --fixture "${FIXTURE}"
grep -Fxq 'unknown database bytes' "${TMP_ROOT}/unknown-cache-extra/databases/unknown.kdbx"

cp -R "${TMP_ROOT}/backup/app-group" "${TMP_ROOT}/multiple-cache-extras"
cp "${FIXTURE}" "${TMP_ROOT}/multiple-cache-extras/databases/first.kdbx"
cp "${FIXTURE}" "${TMP_ROOT}/multiple-cache-extras/databases/second.kdbx"
expect_failure_message multiple-cache-extras 'restore-helper failed: verificationFailed' \
  /usr/bin/swift "${HELPER}" remove-proven-fixture-extra \
  --backup "${TMP_ROOT}/backup/app-group" --live "${TMP_ROOT}/multiple-cache-extras" --fixture "${FIXTURE}"
cmp "${FIXTURE}" "${TMP_ROOT}/multiple-cache-extras/databases/first.kdbx"
cmp "${FIXTURE}" "${TMP_ROOT}/multiple-cache-extras/databases/second.kdbx"

cp -R "${TMP_ROOT}/backup/app-group" "${TMP_ROOT}/multiple-originals-missing"
rm "${TMP_ROOT}/multiple-originals-missing/databases/original.kdbx" "${TMP_ROOT}/multiple-originals-missing/database-list.json"
cp "${FIXTURE}" "${TMP_ROOT}/multiple-originals-missing/databases/test.kdbx"
expect_failure_message multiple-originals-missing 'restore-helper failed: verificationFailed' \
  /usr/bin/swift "${HELPER}" remove-proven-fixture-extra \
  --backup "${TMP_ROOT}/backup/app-group" --live "${TMP_ROOT}/multiple-originals-missing" --fixture "${FIXTURE}"
cmp "${FIXTURE}" "${TMP_ROOT}/multiple-originals-missing/databases/test.kdbx"

/usr/bin/swift "${HELPER}" restore-defaults-file \
  --original "${TMP_ROOT}/original-defaults.plist" \
  --current "${TMP_ROOT}/current-defaults.plist" \
  --output "${TMP_ROOT}/restored-defaults.plist"
/usr/bin/swift "${HELPER}" verify-defaults-file \
  --expected "${TMP_ROOT}/original-defaults.plist" --actual "${TMP_ROOT}/restored-defaults.plist"
echo 'fixture=defaults-semantic-restore result=passed'
echo 'restore-pre-ui-state fixtures passed'
