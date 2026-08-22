#!/usr/bin/env bash
#
# Archive, sign, notarize and staple the direct-download (Developer ID) macOS
# build, then emit the zip that the Sparkle appcast points at.
#
# The Mac App Store build does not go through here — it is archived and uploaded
# the same way the iOS app is (Xcode Cloud / Organizer). This script is only the
# second channel.
#
# Prerequisites, none of which live in the repo:
#   * A "Developer ID Application" certificate in the login keychain.
#   * A Developer ID provisioning profile for com.keevault.app AND one for
#     com.keevault.app.autofill. xcodebuild cannot create Developer ID profiles
#     automatically — make them by hand in the developer portal first.
#   * A notarytool credential profile stored in the keychain:
#       xcrun notarytool store-credentials keeforge-notary \
#         --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
#   * SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY set (see BuildConfig.local.xcconfig);
#     the matching EdDSA private key stays in the login keychain, never in the
#     repo and never in CI logs.
#
# Usage: ci_scripts/build_mac_direct.sh [output-dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUT_DIR="${1:-${REPO_ROOT}/build/mac-direct}"
NOTARY_PROFILE="${KEEFORGE_NOTARY_PROFILE:-keeforge-notary}"
SCHEME="KeeForgeMac"

# A dedicated derived-data path, because this build is the same target and the
# same product name as the App Store build, only regenerated from a different
# spec. Sharing derived data would leave a Sparkle-linked KeeForge.app sitting
# where the App Store build — and the app KeeForgeMacTests hosts in — is
# expected.
DERIVED_DATA="${OUT_DIR}/DerivedData"
ARCHIVE_PATH="${OUT_DIR}/KeeForge.xcarchive"
EXPORT_PATH="${OUT_DIR}/export"
EXPORT_OPTIONS="${REPO_ROOT}/Configs/ExportOptions-DeveloperID.plist"

if [[ ! -f "${EXPORT_OPTIONS}" ]]; then
  echo "error: missing ${EXPORT_OPTIONS}" >&2
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  echo "error: no notarytool credential profile named '${NOTARY_PROFILE}'." >&2
  echo "Create one with: xcrun notarytool store-credentials ${NOTARY_PROFILE} \\" >&2
  echo "  --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>" >&2
  exit 1
fi

cd "${REPO_ROOT}"
rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

# The overlay spec is what makes this the direct-download channel: it adds
# Sparkle and defines KEEFORGE_DIRECT_DOWNLOAD. Plain `xcodegen generate` yields
# the App Store build, so regenerate afterwards before doing anything else.
echo "==> Generating project from the direct-download spec"
xcodegen generate --spec project-direct.yml

restore_appstore_project() {
  echo "==> Restoring the App Store project spec"
  (cd "${REPO_ROOT}" && xcodegen generate >/dev/null)
}
trap restore_appstore_project EXIT

echo "==> Archiving ${SCHEME}"
xcodebuild archive \
  -project KeeForge.xcodeproj \
  -scheme "${SCHEME}" \
  -destination 'generic/platform=macOS' \
  -archivePath "${ARCHIVE_PATH}" \
  -derivedDataPath "${DERIVED_DATA}"

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}"

APP_PATH="${EXPORT_PATH}/KeeForge.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: expected ${APP_PATH} after export" >&2
  exit 1
fi

# The hardening posture is a release invariant, not a preference: no
# get-task-allow, and no com.apple.security.cs.* exceptions. Sparkle 2 needs
# none — Xcode signs its XPC services with the team id and library validation
# permits a same-team load. If an update fails, the signing is wrong; do not
# "fix" it by adding an exception here.
echo "==> Checking entitlements"
ENTITLEMENTS="$(codesign -d --entitlements - --xml "${APP_PATH}" 2>/dev/null | plutil -convert xml1 -o - -)"
if grep -q "com.apple.security.cs." <<<"${ENTITLEMENTS}"; then
  echo "error: build carries a com.apple.security.cs.* exception:" >&2
  grep -o "com.apple.security.cs.[a-z.-]*" <<<"${ENTITLEMENTS}" | sort -u >&2
  exit 1
fi
if grep -q "get-task-allow" <<<"${ENTITLEMENTS}"; then
  echo "error: build carries get-task-allow (debug signing)" >&2
  exit 1
fi
if ! grep -q "com.apple.security.app-sandbox" <<<"${ENTITLEMENTS}"; then
  echo "error: build is not sandboxed; both channels must stay sandboxed" >&2
  exit 1
fi
echo "    hardened runtime + sandbox, no exceptions"

ZIP_PATH="${OUT_DIR}/KeeForge.zip"
echo "==> Zipping for notarization"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "==> Notarizing (this waits for Apple)"
xcrun notarytool submit "${ZIP_PATH}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait

echo "==> Stapling"
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "${APP_PATH}"

# Re-zip after stapling: the ticket is stapled into the .app, and the zip the
# appcast serves must contain the stapled copy so a first launch offline still
# passes Gatekeeper.
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo
echo "Done. Notarized, stapled app: ${APP_PATH}"
echo "Appcast payload:              ${ZIP_PATH}"
echo
echo "Next: sign the zip for Sparkle and add the appcast entry."
echo "  ./bin/sign_update ${ZIP_PATH}"
echo "(sign_update ships in the Sparkle release; it reads the EdDSA private key"
echo " from the login keychain and prints the sparkle:edSignature attribute.)"
