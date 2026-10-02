#!/usr/bin/env bash
# Exercise only a private test keyring and D-Bus. Never query the login keyring.
set -euo pipefail
if [[ ${1:-} == --in-bus ]]; then
  test_binary=$2
  fixture_root=$3
  export SNIPPETS_SECRET_TEST_BUS=$DBUS_SESSION_BUS_ADDRESS
  export SNIPPETS_SECRET_TEST_ROOT=$fixture_root/library
  if [[ $DBUS_SESSION_BUS_ADDRESS == ${SNIPPETS_SECRET_HOST_BUS:-} ]]; then
    printf '%s\n' 'Refusing to test on the desktop bus.' >&2
    exit 1
  fi
  unset SNIPPETS_SUPPORT_DIR
  printf '%s' 'Public fictional keyring fixture password' |
    gnome-keyring-daemon --foreground --components=secrets --unlock \
      --control-directory="$fixture_root/control" >"$fixture_root/daemon.log" 2>&1 &
  fixture_daemon=$!
  trap 'kill "$fixture_daemon" 2>/dev/null || true; wait "$fixture_daemon" 2>/dev/null || true' EXIT
  ready=false
  for ((attempt=0; attempt<50; attempt++)); do
    if gdbus call --session --dest org.freedesktop.DBus \
      --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner \
      org.freedesktop.secrets 2>/dev/null | rg -q true; then
      ready=true
      break
    fi
    sleep 0.1
  done
  if [[ $ready != true ]]; then
    printf '%s\n' 'The isolated test keyring did not start.' >&2
    exit 1
  fi
  G_DEBUG=fatal-warnings "$test_binary" \
    --exact secret_store::tests::native_backend_fixture --ignored --test-threads=1
  exit
fi
if [[ $# != 1 || ! -x $1 ]]; then
  printf '%s\n' 'Usage: secret-service.sh /path/to/compiled/library-test-binary' >&2
  exit 2
fi
if ! "$1" --list | rg -q '^secret_store::tests::native_backend_fixture: test$'; then
  printf '%s\n' 'The selected test binary does not contain the native fixture.' >&2
  exit 2
fi
fixture_root=$(mktemp -d /tmp/snippets-secret-service.XXXXXXXX)
trap 'rm -rf -- "$fixture_root"' EXIT
mkdir -m 700 "$fixture_root/data" "$fixture_root/runtime" "$fixture_root/control"
export XDG_DATA_HOME=$fixture_root/data
export XDG_RUNTIME_DIR=$fixture_root/runtime
export SNIPPETS_SECRET_HOST_BUS=${DBUS_SESSION_BUS_ADDRESS:-}
dbus-run-session -- bash "$0" --in-bus "$1" "$fixture_root"
