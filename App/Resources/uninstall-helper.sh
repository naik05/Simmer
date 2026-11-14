#!/bin/sh
# Removes the Simmer privileged helper installed by install-helper.sh.
#
#   usage: uninstall-helper.sh
#
# Must run as root (the app runs it through "with administrator privileges").
# Stopping the helper sends it SIGTERM, on which it restores stock charging behaviour.
set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL="com.simmer.helper"
BINARY="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

fail() {
    echo "uninstall-helper: $*" >&2
    exit 1
}

[ "$#" -eq 0 ] || fail "usage: uninstall-helper.sh (takes no arguments)"
[ "$(id -u)" -eq 0 ] || fail "must be run as root"

# Not being loaded is fine.
launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true

rm -f "$PLIST" "$BINARY"

echo "Removed $LABEL"
