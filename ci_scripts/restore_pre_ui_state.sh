#!/usr/bin/env bash
# Preserve and restore the KeeForge Mac UI-test state without deleting its container.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_PARENT="${REPO_ROOT}/scratch/release-session"
LIVE_GROUP="${HOME}/Library/Group Containers/group.com.keevault.shared"
DEFAULTS_DOMAIN="com.keevault.app"
SCREENSHOT_FIXTURE="${REPO_ROOT}/TestFixtures/test.kdbx"
HELPER="${SCRIPT_DIR}/restore_pre_ui_state.swift"

mode="inspect"
state_root=""
execute=0
backup_requested=0
self_test_processes=0
confirm=""

usage() {
  cat >&2 <<'USAGE'
Usage: restore_pre_ui_state.sh --state-root PATH [--backup | --execute --confirm RESTORE_PRE_UI_STATE]

Without --backup or --execute, only inspect and verify the saved state.
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    --state-root)
      state_root="${2:-}"
      shift 2
      ;;
    --backup)
      mode="backup"
      backup_requested=1
      shift
      ;;
    --execute)
      execute=1
      mode="restore"
      shift
      ;;
    --confirm)
      confirm="${2:-}"
      shift 2
      ;;
    --self-test-processes)
      self_test_processes=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

if (( self_test_processes == 0 )); then
  [[ -n "${state_root}" ]] || { usage; exit 64; }
  [[ "${backup_requested}" == 0 || "${execute}" == 0 ]] || { usage; exit 64; }
fi

canonical_existing_dir() {
  [[ -d "$1" && ! -L "$1" ]] || return 1
  (cd -P -- "$1" && pwd -P)
}

canonical_parent="$(canonical_existing_dir "${STATE_PARENT}")" || {
  echo "error: release-session scratch directory is unavailable" >&2
  exit 1
}

validate_state_root() {
  local expected_parent actual_parent base
  expected_parent="${canonical_parent}"
  base="$(basename -- "${state_root}")"
  [[ "${base}" != "." && "${base}" != ".." && "${base}" != "/" && -n "${base}" ]] || {
    echo "error: state root must name a directory under ${expected_parent}" >&2
    return 1
  }
  actual_parent="$(canonical_existing_dir "$(dirname -- "${state_root}")")" || {
    echo "error: state root parent is unavailable" >&2
    return 1
  }
  [[ "${actual_parent}" == "${expected_parent}" ]] || {
    echo "error: state root must be directly under ${expected_parent}" >&2
    return 1
  }
  state_root="${actual_parent}/${base}"
}

if (( self_test_processes == 0 )); then
  validate_state_root
  [[ -f "${HELPER}" && ! -L "${HELPER}" && -f "${SCREENSHOT_FIXTURE}" && ! -L "${SCREENSHOT_FIXTURE}" ]] || {
    echo "error: required KeeForge restore helper or screenshot fixture is unavailable" >&2
    exit 1
  }
  [[ "${DEFAULTS_DOMAIN}" == "com.keevault.app" && "${LIVE_GROUP}" == "${HOME}/Library/Group Containers/group.com.keevault.shared" ]] || {
    echo "error: unexpected KeeForge state ownership configuration" >&2
    exit 1
  }
fi

run_helper() {
  /usr/bin/swift "${HELPER}" "$@"
}

process_probe() {
  /usr/bin/pgrep -x "$1" >/dev/null 2>&1
}

require_processes_stopped() {
  local process pgrep_status
  for process in KeeForge KeeForgeAutoFill KeeForgeMacAutoFill KeeForgeMacUITests-Runner KeeForgeUITests-Runner; do
    if process_probe "${process}"; then
      echo "error: ${process} is still running" >&2
      return 1
    else
      pgrep_status=$?
    fi
    [[ "${pgrep_status}" == 1 ]] || {
      echo "error: could not verify ${process} process state" >&2
      return 1
    }
  done
}

run_process_self_test() {
  local fixture expected observed
  for fixture in 0 1 2; do
    case "${fixture}" in
      0|2) expected=1 ;;
      1) expected=0 ;;
    esac
    process_probe() { return "${fixture}"; }
    if require_processes_stopped >/dev/null 2>&1; then
      observed=0
    else
      observed=$?
    fi
    [[ "${observed}" == "${expected}" ]] || {
      echo "error: pgrep fixture ${fixture} returned ${observed}, expected ${expected}" >&2
      return 1
    }
    echo "fixture=pgrep-status-${fixture} result=expected-${observed}"
  done
}

if (( self_test_processes )); then
  run_process_self_test
  exit 0
fi

write_group_state() {
  if [[ -d "${LIVE_GROUP}" && ! -L "${LIVE_GROUP}" ]]; then
    printf present >"${state_root}/group-state"
  else
    printf absent >"${state_root}/group-state"
  fi
}

backup_state() {
  [[ ! -e "${state_root}" && ! -L "${state_root}" ]] || {
    echo "error: state root already exists; preserve it and choose a new name" >&2
    return 1
  }
  require_processes_stopped
  mkdir -m 700 -- "${state_root}"
  write_group_state
  if [[ "$(<"${state_root}/group-state")" == present ]]; then
    run_helper validate-group --group "${LIVE_GROUP}"
    /usr/bin/ditto "${LIVE_GROUP}" "${state_root}/app-group"
    run_helper write-manifest --root "${state_root}" --output "${state_root}/sha256.json"
  fi
  run_helper snapshot-defaults --domain "${DEFAULTS_DOMAIN}" --output "${state_root}/app-defaults.plist"
  echo "backup-complete state_root=${state_root} group_state=$(<"${state_root}/group-state")"
}

require_backup() {
  [[ -d "${state_root}" && ! -L "${state_root}" && -f "${state_root}/group-state" && ! -L "${state_root}/group-state" && -f "${state_root}/app-defaults.plist" && ! -L "${state_root}/app-defaults.plist" ]] || {
    echo "error: incomplete pre-test state root" >&2
    return 1
  }
  [[ "$(<"${state_root}/group-state")" == present ]] || {
    echo "restore-plan=blocked reason=pretest-app-group-absent" >&2
    return 2
  }
  [[ -d "${state_root}/app-group" && ! -L "${state_root}/app-group" && -f "${state_root}/sha256.json" && ! -L "${state_root}/sha256.json" ]] || {
    echo "error: incomplete pre-test App Group backup" >&2
    return 1
  }
  run_helper verify-backup-manifest --root "${state_root}"
  shasum -a 256 "${state_root}/app-defaults.plist" >/dev/null
  [[ -d "${LIVE_GROUP}" && ! -L "${LIVE_GROUP}" ]] || {
    echo "restore-plan=blocked reason=live-app-group-unavailable" >&2
    return 2
  }
  run_helper validate-group --group "${LIVE_GROUP}"
}

inspect_state() {
  require_backup
  run_helper compare-groups --backup "${state_root}/app-group" --live "${LIVE_GROUP}"
  echo "restore-plan=ready mode=read-only"
}

restore_state() {
  [[ "${confirm}" == "RESTORE_PRE_UI_STATE" ]] || {
    echo "error: --execute requires --confirm RESTORE_PRE_UI_STATE" >&2
    return 64
  }
  require_processes_stopped
  require_backup

  local post_root comparison live_extra source_defaults_hash_before source_defaults_hash_after
  post_root="$(mktemp -d "${canonical_parent}/post-ui-state.XXXXXX")"
  /usr/bin/ditto "${LIVE_GROUP}" "${post_root}/app-group"
  run_helper snapshot-defaults --domain "${DEFAULTS_DOMAIN}" --output "${post_root}/app-defaults.plist"
  run_helper write-manifest --root "${post_root}" --output "${post_root}/sha256.json"
  source_defaults_hash_before="$(shasum -a 256 "${state_root}/app-defaults.plist" | awk '{print $1}')"

  comparison="$(run_helper compare-groups --backup "${state_root}/app-group" --live "${LIVE_GROUP}")"
  printf '%s\n' "${comparison}"
  live_extra="$(sed -n 's/.*live_extra=\([0-9][0-9]*\).*/\1/p' <<<"${comparison}")"
  [[ -n "${live_extra}" ]] || { echo "error: could not read App Group comparison" >&2; return 1; }
  if [[ "${live_extra}" != 0 ]]; then
    if ! run_helper remove-proven-fixture-extra --backup "${state_root}/app-group" --live "${LIVE_GROUP}" --fixture "${SCREENSHOT_FIXTURE}"; then
      echo "restore-plan=blocked reason=unproven-live-app-group-files post_state=${post_root}" >&2
      return 3
    fi
  fi

  comparison="$(run_helper compare-groups --backup "${state_root}/app-group" --live "${LIVE_GROUP}")"
  printf '%s\n' "${comparison}"
  live_extra="$(sed -n 's/.*live_extra=\([0-9][0-9]*\).*/\1/p' <<<"${comparison}")"
  [[ "${live_extra}" == 0 ]] || { echo "error: App Group extras remain after proven fixture cleanup" >&2; return 1; }

  /usr/bin/rsync -a --checksum "${state_root}/app-group/" "${LIVE_GROUP}/"
  run_helper restore-defaults --domain "${DEFAULTS_DOMAIN}" --input "${state_root}/app-defaults.plist"
  run_helper verify-defaults --domain "${DEFAULTS_DOMAIN}" --input "${state_root}/app-defaults.plist"
  source_defaults_hash_after="$(shasum -a 256 "${state_root}/app-defaults.plist" | awk '{print $1}')"
  [[ "${source_defaults_hash_before}" == "${source_defaults_hash_after}" ]] || {
    echo "error: pre-test defaults snapshot changed during restoration" >&2
    return 1
  }
  run_helper verify-restored-group --root "${state_root}" --group "${LIVE_GROUP}"
  comparison="$(run_helper compare-groups --backup "${state_root}/app-group" --live "${LIVE_GROUP}")"
  printf '%s\n' "${comparison}"
  grep -Fq 'live_extra=0 backup_missing=0' <<<"${comparison}" || {
    echo "error: restored App Group comparison is incomplete" >&2
    return 1
  }
  echo "restore-complete=verified post_state=${post_root}"
}

case "${mode}" in
  backup) backup_state ;;
  inspect) inspect_state ;;
  restore) restore_state ;;
esac
