#!/usr/bin/env bash
# Actual host SaveFile portal; no account, keyring, PAM or global logging backend.
set -euo pipefail
if [[ $# != 1 || ! -x $1 || -z ${XDG_RUNTIME_DIR:-} ||
      -z ${HYPRLAND_INSTANCE_SIGNATURE:-} || -z ${WAYLAND_DISPLAY:-} ||
      -z ${DBUS_SESSION_BUS_ADDRESS:-} ]]; then
  printf '%s\n' 'Usage: diagnostics-live.sh /path/to/library-test-binary (in the unlocked desktop session)' >&2
  exit 2
fi
test_name=ui::diagnostic_controls::live_tests::live_portal_diagnostic_export_and_delete
if ! "$1" --list | rg -Fx "$test_name: test" > /dev/null; then
  printf '%s\n' 'The selected binary does not contain the native diagnostics fixture.' >&2
  exit 2
fi
fixture_root=$(mktemp -d /tmp/snippets-diagnostics-runtime.XXXXXXXX)
trap 'rm -rf -- "$fixture_root"' EXIT
mkdir -m 700 "$fixture_root/config" "$fixture_root/data" "$fixture_root/cache"
export XDG_CONFIG_HOME=$fixture_root/config
export XDG_DATA_HOME=$fixture_root/data
export XDG_CACHE_HOME=$fixture_root/cache
export GSETTINGS_BACKEND=memory
export GDK_BACKEND=wayland
export GTK_A11Y=none
export SNIPPETS_DIAGNOSTICS_LIVE=public-private-roots
# Retain only the actual desktop portal for this previously listed acceptance.
# Owned portal input is guarded; the returned path is checked before any write.
# Service::start(false) never installs a process-global sink or mirrors to OS logs.
unset SNIPPETS_SUPPORT_DIR GDK_DEBUG GTK_USE_PORTAL GIO_USE_VFS
G_DEBUG=fatal-warnings "$1" --exact "$test_name" --ignored --test-threads=1 --nocapture
