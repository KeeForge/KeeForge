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
#   * Developer ID provisioning profiles for com.keevault.app and
#     com.keevault.app.autofill. Xcode creates both on demand — the archive and
#     export below pass -allowProvisioningUpdates — so no portal visit is
#     needed. Making them by hand still works if you prefer to pin the
#     entitlements a profile authorizes.
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

# Resolving the direct spec's extra dependency rewrites the workspace's
# Package.resolved originHash. That file belongs to the checked-in App Store
# project, so restore it too — otherwise every release run leaves the tree dirty.
RESOLVED_FILE="KeeForge.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

restore_appstore_project() {
  echo "==> Restoring the App Store project spec"
  (cd "${REPO_ROOT}" && xcodegen generate >/dev/null)
  if git -C "${REPO_ROOT}" ls-files --error-unmatch "${RESOLVED_FILE}" >/dev/null 2>&1; then
    git -C "${REPO_ROOT}" checkout -- "${RESOLVED_FILE}" 2>/dev/null || true
  fi
}
trap restore_appstore_project EXIT

echo "==> Archiving ${SCHEME}"
xcodebuild archive \
  -project KeeForge.xcodeproj \
  -scheme "${SCHEME}" \
  -destination 'generic/platform=macOS' \
  -archivePath "${ARCHIVE_PATH}" \
  -derivedDataPath "${DERIVED_DATA}" \
  -allowProvisioningUpdates

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -allowProvisioningUpdates

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
#
# Checked on the app *and* on every nested bundle it embeds. The AutoFill
# extension and Sparkle's XPC services are separately signed with their own
# entitlements, so an exception added to one of them would never appear in the
# app's own and would otherwise ship unnoticed.
check_hardening() {
  local bundle="$1"
  local entitlements
  entitlements="$(codesign -d --entitlements - --xml "${bundle}" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)"

  if grep -q "com.apple.security.cs." <<<"${entitlements}"; then
    echo "error: ${bundle##*/} carries a com.apple.security.cs.* exception:" >&2
    grep -o "com.apple.security.cs.[a-z.-]*" <<<"${entitlements}" | sort -u >&2
    return 1
  fi
  if grep -q "get-task-allow" <<<"${entitlements}"; then
    echo "error: ${bundle##*/} carries get-task-allow (debug signing)" >&2
    return 1
  fi
  echo "    ${bundle##*/}: no exceptions"
}

echo "==> Checking entitlements"
APP_ENTITLEMENTS="$(codesign -d --entitlements - --xml "${APP_PATH}" 2>/dev/null | plutil -convert xml1 -o - -)"
if ! grep -q "com.apple.security.app-sandbox" <<<"${APP_ENTITLEMENTS}"; then
  echo "error: build is not sandboxed; both channels must stay sandboxed" >&2
  exit 1
fi

check_hardening "${APP_PATH}"
while IFS= read -r NESTED; do
  check_hardening "${NESTED}"
done < <(find "${APP_PATH}/Contents" \
  \( -name "*.appex" -o -name "*.xpc" -o -name "*.app" \) -print)

# The AutoFill extension must stay sandboxed in its own right: it is the process
# that holds decrypted vault contents while filling.
APPEX="$(find "${APP_PATH}/Contents" -name "*.appex" -print -quit)"
if [[ -n "${APPEX}" ]]; then
  if ! codesign -d --entitlements - --xml "${APPEX}" 2>/dev/null \
    | plutil -convert xml1 -o - - \
    | grep -q "com.apple.security.app-sandbox"; then
    echo "error: ${APPEX##*/} is not sandboxed" >&2
    exit 1
  fi
fi
echo "    hardened runtime + sandbox, no exceptions"

# An update channel is only as good as the two values that authenticate it. An
# empty SUPublicEDKey makes Sparkle refuse every update (fail-closed, but the
# channel is then dead), and a plaintext feed hands an on-path attacker the
# update metadata. Both are build-time settings, so catch them here rather than
# after the appcast is live.
echo "==> Checking the Sparkle update channel"
BUILT_FEED_URL="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)"
BUILT_ED_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "${BUILT_ED_KEY}" ]]; then
  echo "error: SUPublicEDKey is empty; a direct build with no update key cannot ever update." >&2
  echo "Set SPARKLE_PUBLIC_ED_KEY in BuildConfig.local.xcconfig." >&2
  exit 1
fi
if [[ "${BUILT_FEED_URL}" != https://* ]]; then
  echo "error: SUFeedURL must be an https:// URL, got '${BUILT_FEED_URL}'" >&2
  exit 1
fi
echo "    appcast ${BUILT_FEED_URL}, update key present"

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

# sign_update ships inside the Sparkle SPM artifact bundle, which the archive
# above already resolved into this run's derived data. Locating it there keeps
# the appcast signature a step of this script rather than a tool the releaser has
# to go find; the EdDSA private key is read from the login keychain and never
# printed.
SIGN_UPDATE="$(find "${DERIVED_DATA}/SourcePackages/artifacts" -name sign_update -path "*/Sparkle/bin/*" -print -quit 2>/dev/null || true)"
if [[ -z "${SIGN_UPDATE}" ]]; then
  echo "error: could not find sign_update under ${DERIVED_DATA}/SourcePackages/artifacts" >&2
  exit 1
fi

echo "==> Signing the appcast payload"
SIGNATURE_ATTRS="$("${SIGN_UPDATE}" "${ZIP_PATH}")"

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_PATH}/Contents/Info.plist")"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)"

echo
echo "Done. Notarized, stapled app: ${APP_PATH}"
echo "Appcast payload:              ${ZIP_PATH}"
echo
echo "Appcast entry for ${BUILT_FEED_URL} — paste into <channel>, newest first:"
echo
cat <<APPCAST_ITEM
        <item>
            <title>${SHORT_VERSION}</title>
            <sparkle:version>${BUILD_NUMBER}</sparkle:version>
            <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_SYSTEM}</sparkle:minimumSystemVersion>
            <sparkle:releaseNotesLink>https://keeforge.com/changelog</sparkle:releaseNotesLink>
            <enclosure url="https://downloads.keeforge.com/KeeForge-${SHORT_VERSION}.zip"
                       ${SIGNATURE_ATTRS}
                       type="application/octet-stream" />
        </item>
APPCAST_ITEM
echo
echo "Upload ${ZIP_PATH##*/} to R2 as KeeForge-${SHORT_VERSION}.zip, reachable at the enclosure URL above."
