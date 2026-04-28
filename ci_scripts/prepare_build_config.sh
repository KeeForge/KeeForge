#!/bin/bash
set -euo pipefail

REPO_ROOT="${1:-$(pwd)}"
LOCAL_CONFIG_PATH="${REPO_ROOT}/BuildConfig.local.xcconfig"
METADATA_CONFIG_PATH="${REPO_ROOT}/BuildMetadata.xcconfig"
CI_PLACEHOLDER_DROPBOX_APP_KEY="CI_PLACEHOLDER_DROPBOX_APP_KEY"
CI_PLACEHOLDER_ONEDRIVE_CLIENT_ID="00000000-0000-0000-0000-000000000000"

is_ci_environment() {
  [[ -n "${CI:-}" || -n "${CI_XCODEBUILD_ACTION:-}" || -n "${CI_PRIMARY_REPOSITORY_PATH:-}" || -n "${GITHUB_ACTIONS:-}" ]]
}

write_metadata() {
  local hash
  hash=$(/usr/bin/git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo dev)
  printf "GIT_COMMIT_HASH = %s\n" "${hash}" > "${METADATA_CONFIG_PATH}"
}

bootstrap_local_config_from_env() {
  if [[ "${BOOTSTRAP_LOCAL_CONFIG_FROM_ENV:-0}" != "1" ]]; then
    return
  fi

  if [[ -f "${LOCAL_CONFIG_PATH}" ]]; then
    return
  fi

  local dropbox_app_key="${DROPBOX_APP_KEY:-}"
  local onedrive_client_id="${ONEDRIVE_CLIENT_ID:-}"
  if [[ -z "${dropbox_app_key}" ]] && is_ci_environment; then
    dropbox_app_key="${CI_PLACEHOLDER_DROPBOX_APP_KEY}"
  fi
  if [[ -z "${onedrive_client_id}" ]] && is_ci_environment; then
    onedrive_client_id="${CI_PLACEHOLDER_ONEDRIVE_CLIENT_ID}"
  fi

  if [[ -z "${dropbox_app_key}" ]]; then
    return
  fi

  {
    printf "// Generated from environment variables.\n"
    if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
      printf "DEVELOPMENT_TEAM = %s\n" "${DEVELOPMENT_TEAM}"
    fi
    printf "DROPBOX_APP_KEY = %s\n" "${dropbox_app_key}"
    if [[ -n "${onedrive_client_id}" ]]; then
      printf "ONEDRIVE_CLIENT_ID = %s\n" "${onedrive_client_id}"
    fi
  } > "${LOCAL_CONFIG_PATH}"
}

read_setting() {
  local key="$1"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.+)[[:space:]]*$/\\1/p" "${LOCAL_CONFIG_PATH}" | tail -n 1
}

fail_with_message() {
  echo "error: $1" >&2
  exit 1
}

validate_setting() {
  local key="$1"
  local placeholder="$2"
  local value

  value="$(read_setting "${key}")"
  value="$(printf "%s" "${value}" | tr -d '[:space:]')"

  if [[ "${key}" == "DROPBOX_APP_KEY" && "${value}" == "${CI_PLACEHOLDER_DROPBOX_APP_KEY}" ]] && is_ci_environment; then
    return
  fi
  if [[ "${key}" == "ONEDRIVE_CLIENT_ID" && "${value}" == "${CI_PLACEHOLDER_ONEDRIVE_CLIENT_ID}" ]] && is_ci_environment; then
    return
  fi

  if [[ -z "${value}" || "${value}" == "${placeholder}" ]]; then
    fail_with_message "Set ${key} in BuildConfig.local.xcconfig before building. Start from BuildConfig.local.example.xcconfig."
  fi
}

write_metadata
bootstrap_local_config_from_env

if [[ ! -f "${LOCAL_CONFIG_PATH}" ]]; then
  fail_with_message "Missing BuildConfig.local.xcconfig. Copy BuildConfig.local.example.xcconfig to BuildConfig.local.xcconfig and fill in DROPBOX_APP_KEY. Add ONEDRIVE_CLIENT_ID to test OneDrive OAuth."
fi

validate_setting "DROPBOX_APP_KEY" "YOUR_DROPBOX_APP_KEY"
validate_setting "DROPBOX_APP_KEY" "DROPBOX_APP_KEY"
