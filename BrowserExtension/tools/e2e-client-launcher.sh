#!/bin/sh
# The Mac UI test runner is App Sandboxed, and a child of a sandboxed process cannot start the
# host in a sandbox of its own. Installed as
#   ~/Library/Application Scripts/com.keevault.app.uitests.xctrunner/keeforge-e2e-client
# it lets MacBrowserBridgeUITests start e2e-client.mjs, and MacBrowserExtensionUITests start
# e2e-browser.mjs (which starts Chrome, which starts the host), through NSUserUnixTask, outside that sandbox.
case "$1" in
  */BrowserExtension/tools/e2e-client.mjs|*/BrowserExtension/tools/e2e-browser.mjs) ;;
  *) echo "e2e-client-launcher: not an e2e driver: $1" >&2; exit 2 ;;
esac
node=/opt/homebrew/bin/node
[ -x "$node" ] || { echo "e2e-client-launcher: no Node at $node" >&2; exit 4; }
user=$(/usr/bin/id -un)
home=$(eval echo "~$user")
log="${TMPDIR:-/tmp}/keeforge-$(basename "$1" .mjs).log"
# NSUserUnixTask does not reliably deliver stderr to the test; keep the last run's for diagnosis.
exec 2>"$log"
echo "args: $*" >&2
exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="$home" USER="$user" LOGNAME="$user" LANG=en_US.UTF-8 "$node" "$@"
