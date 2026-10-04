#!/usr/bin/env bash
# Actual desktop portal, public private-root library, no keyring/PAM/clipboard.
set -euo pipefail
if [[ $# != 1 || ! -x $1 || -z ${XDG_RUNTIME_DIR:-} ||
      -z ${HYPRLAND_INSTANCE_SIGNATURE:-} || -z ${WAYLAND_DISPLAY:-} ||
      -z ${DBUS_SESSION_BUS_ADDRESS:-} ]]; then
  printf '%s\n' 'Usage: backup-live.sh /path/to/library-test-binary (in the unlocked desktop session)' >&2
  exit 2
fi
test_name=backup_ui::live_tests::live_portal_backup_export_and_restore
if ! "$1" --list | rg -Fx "$test_name: test" > /dev/null; then
  printf '%s\n' 'The selected binary does not contain the native backup fixture.' >&2
  exit 2
fi
fixture_root=$(mktemp -d /tmp/snippets-backup-runtime.XXXXXXXX)
trap 'rm -rf -- "$fixture_root"' EXIT
mkdir -m 700 "$fixture_root/config" "$fixture_root/data" "$fixture_root/cache"
export XDG_CONFIG_HOME=$fixture_root/config
export XDG_DATA_HOME=$fixture_root/data
export XDG_CACHE_HOME=$fixture_root/cache
export GSETTINGS_BACKEND=memory
export GDK_BACKEND=wayland
export SNIPPETS_BACKUP_LIVE=public-private-roots
# The host portal is deliberately retained to test Omarchy's normal file chooser.
# Only verified portal windows receive input, and only public fixture paths are
# typed. The selected path is asserted before credentials or publication.
unset SNIPPETS_SUPPORT_DIR GDK_DEBUG GTK_USE_PORTAL GIO_USE_VFS
G_DEBUG=fatal-warnings "$1" --exact "$test_name" --ignored --test-threads=1 --nocapture
