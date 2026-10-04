#!/usr/bin/env bash
# Explicit native login-launch acceptance on the existing desktop/user manager.
# The Rust fixture owns private registration/data and unique runtime-only units.
set -euo pipefail
if [[ $# != 2 || ! -x $1 || ! -d $2 || -z ${XDG_RUNTIME_DIR:-} ||
      -z ${DBUS_SESSION_BUS_ADDRESS:-} || -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ||
      -z ${WAYLAND_DISPLAY:-} ]]; then
  printf '%s\n' 'Usage: login-startup-live.sh /path/to/library-test-binary /path/to/release-directory (in the unlocked desktop session)' >&2
  exit 2
fi
for binary in snippets snippets-cli snippets-owner-auth; do
  if [[ ! -x $2/$binary ]]; then
    printf '%s\n' 'The release directory is incomplete.' >&2
    exit 2
  fi
done
test_name=ui::settings::live_tests::live_native_login_launch
if ! "$1" --list | rg -Fx "$test_name: test" > /dev/null; then
  printf '%s\n' 'The selected library test binary does not contain the native login fixture.' >&2
  exit 2
fi
export SNIPPETS_STARTUP_TEST_RELEASE=$2
G_DEBUG=fatal-warnings "$1" --exact "$test_name" --ignored --test-threads=1
