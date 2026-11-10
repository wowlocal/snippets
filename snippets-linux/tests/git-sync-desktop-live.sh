#!/usr/bin/env bash
# Native Git Sync window acceptance with an isolated bus, keyring and data
# root, and a loopback `git http-backend`. Shares only the compositor; never
# the login keyring, the user's library, ssh agent or git configuration.
#   tests/git-sync-desktop-live.sh /path/to/compiled/library-test-binary
set -euo pipefail
umask 077
test_name=git_ui::live_tests::live_git_window_creates_joins_reviews_and_disconnects
if [[ ${1:-} == --in-bus ]]; then
  test_binary=$2
  fixture_root=$3
  export SNIPPETS_SECRET_TEST_BUS=$DBUS_SESSION_BUS_ADDRESS
  if [[ $DBUS_SESSION_BUS_ADDRESS == ${SNIPPETS_SECRET_HOST_BUS:-} ]]; then
    printf '%s\n' 'Refusing to test on the desktop bus.' >&2
    exit 1
  fi
  unset SNIPPETS_SUPPORT_DIR SSH_AUTH_SOCK SSH_AGENT_PID
  # The fixture daemon stores its keyrings under XDG_DATA_HOME; never start
  # it unless that is inside this fixture.
  if [[ ${XDG_DATA_HOME:-} != "$fixture_root/data" || ! -d $XDG_DATA_HOME ]]; then
    printf '%s\n' 'Refusing to start a keyring outside the fixture.' >&2
    exit 1
  fi
  printf '%s' 'Public fictional keyring fixture password' |
    gnome-keyring-daemon --foreground --components=secrets --unlock \
      --control-directory="$fixture_root/control" >"$fixture_root/daemon.log" 2>&1 &
  fixture_daemon=$!
  trap 'kill "$fixture_daemon" 2>/dev/null || true; wait "$fixture_daemon" 2>/dev/null || true' EXIT
  ready=false
  for ((attempt=0; attempt<50; attempt++)); do
    if gdbus call --session --dest org.freedesktop.DBus \
      --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner \
      org.freedesktop.secrets 2>/dev/null | grep -q true; then
      ready=true
      break
    fi
    sleep 0.1
  done
  [[ $ready == true ]] || { printf '%s\n' 'The isolated test keyring did not start.' >&2; exit 1; }
  G_DEBUG=fatal-warnings "$test_binary" --exact "$test_name" --ignored --test-threads=1
  exit
fi
if [[ $# != 1 || ! -x $1 || -z ${WAYLAND_DISPLAY:-} || -z ${XDG_RUNTIME_DIR:-} ]]; then
  printf '%s\n' 'Usage: git-sync-desktop-live.sh /path/to/library-test-binary (in the unlocked desktop session)' >&2
  exit 2
fi
# The real keyring directory, resolved before XDG_DATA_HOME is overridden.
real_keyrings=${XDG_DATA_HOME:-$HOME/.local/share}/keyrings
here=$(cd "$(dirname "$0")" && pwd)
server_script=${SNIPPETS_GIT_HTTP_SERVER:-$here/../../scripts/git-http-test-server.py}
[[ -f $server_script ]] || { printf '%s\n' 'git-http-test-server.py not found' >&2; exit 2; }
host_runtime=$XDG_RUNTIME_DIR
if [[ $WAYLAND_DISPLAY != /* ]]; then
  export WAYLAND_DISPLAY=$host_runtime/$WAYLAND_DISPLAY
fi
[[ -S $WAYLAND_DISPLAY ]] || { printf '%s\n' 'The desktop compositor is unavailable.' >&2; exit 1; }
fixture_root=$(mktemp -d /tmp/snippets-git-desktop.XXXXXXXX)
# Short path keeps sockets within sockaddr_un.
fixture_runtime=$(mktemp -d /tmp/sg.XXXXXX)
server_pid=''
cleanup() {
  [[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  [[ $fixture_root == /tmp/snippets-git-desktop.* ]] && rm -rf -- "$fixture_root"
  [[ $fixture_runtime == /tmp/sg.* ]] && rm -rf -- "$fixture_runtime"
}
trap cleanup EXIT
mkdir -m 700 "$fixture_root/data" "$fixture_root/control" "$fixture_root/config" "$fixture_root/cache" "$fixture_root/http"
[[ -d $host_runtime/hypr ]] && ln -s -- "$host_runtime/hypr" "$fixture_runtime/hypr"
fixture_git() { GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -c user.name=Hand -c user.email=hand@example.invalid "$@"; }
fixture_git init --quiet --bare --initial-branch=main "$fixture_root/http/library.git"
fixture_git init --quiet --bare --initial-branch=main "$fixture_root/http/plain.git"
# A branch that already has a README.
fixture_git init --quiet --bare --initial-branch=main "$fixture_root/http/foreign.git"
fixture_git init --quiet --initial-branch=main "$fixture_root/readme-work"
printf '%s\n' '# Notes' >"$fixture_root/readme-work/README.md"
fixture_git -C "$fixture_root/readme-work" add README.md
fixture_git -C "$fixture_root/readme-work" commit --quiet -m 'Add README'
fixture_git -C "$fixture_root/readme-work" push --quiet "$fixture_root/http/foreign.git" main
python3 -I -c 'import secrets; print(secrets.token_hex(20))' >"$fixture_root/token"
python3 -I "$server_script" --root "$fixture_root/http" --username tester \
  --token-file "$fixture_root/token" >"$fixture_root/http.out" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do grep -q '^READY ' "$fixture_root/http.out" 2>/dev/null && break; sleep 0.1; done
port=$(awk '/^READY /{print $2}' "$fixture_root/http.out")
[[ -n $port ]] || { printf '%s\n' 'git test server did not start' >&2; exit 1; }
# A private session bus: no host service directories, so nothing on the
# desktop bus (keyring, portals, accessibility, systemd) can be activated.
cat >"$fixture_root/bus.conf" <<XML
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=$fixture_runtime</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="$UID"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
XML
export SNIPPETS_GIT_LIVE_HTTP_URL="http://127.0.0.1:$port/library.git"
export SNIPPETS_GIT_LIVE_HTTP_PLAIN_URL="http://127.0.0.1:$port/plain.git"
export SNIPPETS_GIT_LIVE_HTTP_FOREIGN_URL="http://127.0.0.1:$port/foreign.git"
export SNIPPETS_GIT_LIVE_PLAIN_REPO=$fixture_root/http/plain.git
export SNIPPETS_GIT_LIVE_HTTP_USERNAME=tester
export SNIPPETS_GIT_LIVE_HTTP_TOKEN_FILE=$fixture_root/token
export SNIPPETS_GIT_ALLOW_INSECURE_LOOPBACK=1
export XDG_DATA_HOME=$fixture_root/data
export XDG_CONFIG_HOME=$fixture_root/config
export XDG_CACHE_HOME=$fixture_root/cache
export XDG_RUNTIME_DIR=$fixture_runtime
export GSETTINGS_BACKEND=memory
export GIO_USE_VFS=local
export GDK_DEBUG=no-portals
export GTK_A11Y=none
unset GTK_USE_PORTAL
export SNIPPETS_SECRET_HOST_BUS=${DBUS_SESSION_BUS_ADDRESS:-}
login_keyrings() { find "$real_keyrings" -maxdepth 1 -printf '%f %s %T@\n' 2>/dev/null | sort; }
before=$(login_keyrings)
# Capture the result first: the keyring comparison runs even after a failure.
status=0
dbus-run-session --config-file="$fixture_root/bus.conf" -- bash "$0" --in-bus "$1" "$fixture_root" || status=$?
after=$(login_keyrings)
if [[ $before != "$after" ]]; then
  printf '%s\n' 'The login keyring directory changed during the fixture run.' >&2
  exit 1
fi
[[ $status == 0 ]] || exit "$status"
printf '%s\n' 'git sync desktop acceptance: ok'
