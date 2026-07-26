#!/bin/bash
set -euo pipefail

REPO_ROOT="${1:-$(pwd)}"
LOCAL_CONFIG_PATH="${REPO_ROOT}/BuildConfig.local.xcconfig"
METADATA_CONFIG_PATH="${REPO_ROOT}/BuildMetadata.xcconfig"
# The Dropbox key is interpolated into a CFBundleURLScheme (`db-$(DROPBOX_APP_KEY)`),
# so the CI placeholder must itself be a legal RFC1738 scheme tail: alphanumerics,
# period, hyphen, or plus only. Underscores get the archive rejected by App Store
# Connect with ITMS-90158.
CI_PLACEHOLDER_DROPBOX_APP_KEY="ciplaceholderdropboxappkey"
LEGACY_CI_PLACEHOLDER_DROPBOX_APP_KEY="CI_PLACEHOLDER_DROPBOX_APP_KEY"
CI_PLACEHOLDER_ONEDRIVE_CLIENT_ID="00000000-0000-0000-0000-000000000000"

is_ci_environment() {
  [[ -n "${CI:-}" || -n "${CI_XCODEBUILD_ACTION:-}" || -n "${CI_PRIMARY_REPOSITORY_PATH:-}" || -n "${GITHUB_ACTIONS:-}" ]]
}

# Placeholders are fine for simulator test runs, but an archive is a shippable
# binary: it must carry the real keys or fail loudly here.
requires_real_cloud_keys() {
  [[ "${REQUIRE_REAL_CLOUD_KEYS:-0}" == "1" || "${CI_XCODEBUILD_ACTION:-}" == "archive" ]]
}

is_dropbox_placeholder() {
  [[ "$1" == "${CI_PLACEHOLDER_DROPBOX_APP_KEY}" || "$1" == "${LEGACY_CI_PLACEHOLDER_DROPBOX_APP_KEY}" ]]
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

# Fails when the value is empty or matches any listed placeholder. The literal
# key name counts as a placeholder because that is what a botched substitution
# leaves behind, and the app refuses it at runtime.
validate_setting() {
  local key="$1"
  shift
  local value placeholder

  value="$(read_setting "${key}")"
  value="$(printf "%s" "${value}" | tr -d '[:space:]')"

  if [[ "${key}" == "DROPBOX_APP_KEY" ]] && is_dropbox_placeholder "${value}"; then
    if requires_real_cloud_keys; then
      fail_with_message "DROPBOX_APP_KEY is still the CI placeholder while producing an archive. Set the real DROPBOX_APP_KEY environment variable on this workflow."
    fi
    if is_ci_environment; then
      return
    fi
  fi

  if [[ -z "${value}" ]]; then
    fail_with_message "Set ${key} in BuildConfig.local.xcconfig before building. Start from BuildConfig.local.example.xcconfig."
  fi
  for placeholder in "$@"; do
    if [[ "${value}" == "${placeholder}" ]]; then
      fail_with_message "Set ${key} in BuildConfig.local.xcconfig before building. Start from BuildConfig.local.example.xcconfig."
    fi
  done
}

# ONEDRIVE_CLIENT_ID is optional for local development (the app just disables
# OneDrive sign-in), but an archive is a shippable binary: it must carry a real
# client ID or fail loudly here, same as DROPBOX_APP_KEY.
validate_onedrive_client_id() {
  local value

  value="$(read_setting "ONEDRIVE_CLIENT_ID")"
  value="$(printf "%s" "${value}" | tr -d '[:space:]')"

  if [[ -z "${value}" || "${value}" == "YOUR_ONEDRIVE_CLIENT_ID" \
        || "${value}" == "ONEDRIVE_CLIENT_ID" \
        || "${value}" == "${CI_PLACEHOLDER_ONEDRIVE_CLIENT_ID}" ]]; then
    if requires_real_cloud_keys; then
      fail_with_message "ONEDRIVE_CLIENT_ID is missing or still a placeholder while producing an archive. Set the real ONEDRIVE_CLIENT_ID environment variable on this workflow."
    fi
  fi
}

write_metadata
bootstrap_local_config_from_env

if [[ ! -f "${LOCAL_CONFIG_PATH}" ]]; then
  fail_with_message "Missing BuildConfig.local.xcconfig. Copy BuildConfig.local.example.xcconfig to BuildConfig.local.xcconfig and fill in DROPBOX_APP_KEY. Add ONEDRIVE_CLIENT_ID to test OneDrive OAuth."
fi

validate_setting "DROPBOX_APP_KEY" "YOUR_DROPBOX_APP_KEY" "DROPBOX_APP_KEY"
validate_onedrive_client_id
