#!/bin/sh
# Installs the Simmer privileged helper as a LaunchDaemon.
#
#   usage: install-helper.sh <absolute path to the SimmerHelper binary>
#
# Must run as root (the app runs it through "with administrator privileges").
set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 022

LABEL="com.simmer.helper"
TOOLS_DIR="/Library/PrivilegedHelperTools"
DAEMONS_DIR="/Library/LaunchDaemons"
BINARY="$TOOLS_DIR/$LABEL"
PLIST="$DAEMONS_DIR/$LABEL.plist"

fail() {
    echo "install-helper: $*" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail "usage: install-helper.sh <absolute path to SimmerHelper>"
SOURCE="$1"

[ "$(id -u)" -eq 0 ] || fail "must be run as root"
case "$SOURCE" in
    /*) ;;
    *) fail "the helper path must be absolute: $SOURCE" ;;
esac
[ -f "$SOURCE" ] || fail "helper binary not found: $SOURCE"
[ ! -L "$SOURCE" ] || fail "helper binary must not be a symbolic link: $SOURCE"
[ -x "$SOURCE" ] || fail "helper binary is not executable: $SOURCE"

# Stop a previous installation. Not being loaded is fine.
launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true

install -d -o root -g wheel -m 755 "$TOOLS_DIR"
install -o root -g wheel -m 755 "$SOURCE" "$BINARY"

# Write the plist to a temporary file first so launchd never sees a partial one.
TEMP_PLIST="$(mktemp "$DAEMONS_DIR/.$LABEL.XXXXXX")"
trap 'rm -f "$TEMP_PLIST"' EXIT
cat > "$TEMP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BINARY</string>
	</array>
	<key>MachServices</key>
	<dict>
		<key>$LABEL</key>
		<true/>
	</dict>
	<key>KeepAlive</key>
	<true/>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLIST
chown root:wheel "$TEMP_PLIST"
chmod 644 "$TEMP_PLIST"
mv -f "$TEMP_PLIST" "$PLIST"
trap - EXIT

# A service the user disabled earlier would refuse to bootstrap.
launchctl enable "system/$LABEL"

# bootout is asynchronous: retry briefly while the old instance is still shutting down.
attempt=0
until launchctl bootstrap system "$PLIST"; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 5 ] || fail "launchctl could not load $PLIST"
    sleep 1
done

echo "Installed $LABEL"
