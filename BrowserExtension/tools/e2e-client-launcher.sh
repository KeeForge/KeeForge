#!/bin/sh
# The Mac UI test runner is App Sandboxed, and a child of a sandboxed process cannot start the
# host in a sandbox of its own. Installed as
#   ~/Library/Application Scripts/com.keevault.app.uitests.xctrunner/keeforge-e2e-client
# it lets MacBrowserBridgeUITests start e2e-client.mjs through NSUserUnixTask, outside that sandbox.
case "$1" in
  */BrowserExtension/tools/e2e-client.mjs) ;;
  *) echo "e2e-client-launcher: not the e2e client: $1" >&2; exit 2 ;;
esac
node=/opt/homebrew/bin/node
[ -x "$node" ] || { echo "e2e-client-launcher: no Node at $node" >&2; exit 4; }
user=$(/usr/bin/id -un)
home=$(eval echo "~$user")
log="${TMPDIR:-/tmp}/keeforge-e2e-client.log"
# NSUserUnixTask does not reliably deliver stderr to the test; keep the last run's for diagnosis.
exec 2>"$log"
echo "args: $*" >&2
exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="$home" USER="$user" LOGNAME="$user" LANG=en_US.UTF-8 "$node" "$@"
