#!/usr/bin/env bash
# The IBus engine against a private ibus-daemon on a private session bus, with a
# fictional GNOME Shell and a fictional Snippets app (tests/ibus/). Nothing
# reaches the desktop's IBus, input sources, keyring or library.
#
#   tests/ibus-engine-live.sh /path/to/snippets-ibus [transcript]
#
# Needs dbus-run-session, ibus-daemon (or SNIPPETS_IBUS_DAEMON) and Python GI
# with the IBus typelib. The daemon launches the engine from a component XML, as
# an installed GNOME session does; engine output goes to the daemon's log. The
# transcript, one JSON line per observation, lets two engine builds be compared
# with diff.
set -euo pipefail
umask 077
if [[ $# -lt 1 || $# -gt 2 || ! -x $1 ]]; then
  printf '%s\n' 'Usage: ibus-engine-live.sh /path/to/snippets-ibus [transcript]' >&2
  exit 2
fi
engine=$(realpath "$1")
transcript=${2:-/dev/stdout}
here=$(cd "$(dirname "$0")" && pwd)
daemon=${SNIPPETS_IBUS_DAEMON:-$(command -v ibus-daemon || true)}
[[ -n $daemon && -x $daemon ]] || { printf '%s\n' 'ibus-daemon not found (set SNIPPETS_IBUS_DAEMON)' >&2; exit 2; }
command -v dbus-run-session >/dev/null || { printf '%s\n' 'dbus-run-session not found' >&2; exit 2; }
python3 -c 'import gi; gi.require_version("IBus", "1.0"); from gi.repository import IBus' \
  || { printf '%s\n' 'Python GI with the IBus typelib is required' >&2; exit 2; }

root=$(mktemp -d /tmp/sie.XXXXXX)
cleanup() {
  set +e
  for pid in $(cat "$root/pids" 2>/dev/null); do kill "$pid" 2>/dev/null; done
  [[ $root == /tmp/sie.* ]] && rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$root/bin" "$root/home" "$root/config" "$root/cache" "$root/run" "$root/components"
chmod 700 "$root/run"
# The engine accepts only the `snippets` executable installed beside it, so the
# fictional app runs from a copy of the interpreter under that name.
cp "$engine" "$root/bin/snippets-ibus"
interpreter=$(realpath "$(command -v python3)")
cp "$interpreter" "$root/bin/snippets"
pythonhome=$(python3 -c 'import sys; print(sys.prefix + ":" + sys.exec_prefix)')
# As installed: the daemon reads this component and launches the engine itself
# with --ibus (scripts/linux-install-metadata.py writes the same XML).
cat >"$root/components/snippets.xml" <<EOF
<?xml version='1.0' encoding='utf-8'?>
<component>
  <name>org.freedesktop.IBus.Snippets</name>
  <description>Snippets text expansion</description>
  <exec>$root/bin/snippets-ibus --ibus</exec>
  <version>0.1.0</version>
  <license>MIT</license>
  <author>Snippets</author>
  <homepage>https://github.com/wowlocal/snippets</homepage>
  <textdomain></textdomain>
  <engines>
    <engine>
      <name>snippets</name>
      <longname>Snippets</longname>
      <description>Snippets text expansion</description>
      <language>en</language>
      <license>MIT</license>
      <author>Snippets</author>
      <layout>default</layout>
      <symbol>S</symbol>
    </engine>
  </engines>
</component>
EOF
locale=C.UTF-8
compose=0
if locale -a 2>/dev/null | grep -qix 'en_US.utf8\|en_US.UTF-8'; then locale=en_US.UTF-8; compose=1; fi

# Everything below runs on its own session bus with its own HOME and runtime.
cat >"$root/session.sh" <<'EOF'
set -euo pipefail
record() { printf '%s\n' "$1" >>"$ROOT/pids"; }
wait_for() {
  for _ in $(seq 1 100); do grep -q READY "$1" 2>/dev/null && return 0; sleep 0.05; done
  printf 'did not start: %s\n' "$1" >&2; cat "$1" >&2; return 1
}
python3 "$HERE/ibus/fake_shell.py" >"$ROOT/shell.out" 2>&1 & record $!
wait_for "$ROOT/shell.out"
"$DAEMON" --address="unix:path=$ROOT/ibus.socket" --panel=disable --emoji-extension=disable \
  --config=disable --cache=none --single >"$ROOT/daemon.out" 2>&1 & record $!
for _ in $(seq 1 100); do [[ -S $ROOT/ibus.socket ]] && break; sleep 0.05; done
[[ -S $ROOT/ibus.socket ]] || { cat "$ROOT/daemon.out" >&2; exit 1; }
PYTHONHOME="$PYTHONHOME_FOR_APP" "$ROOT/bin/snippets" "$HERE/ibus/fake_app.py" "$XDG_RUNTIME_DIR" \
  "$ROOT/app.log" >"$ROOT/app.out" 2>&1 & record $!
wait_for "$ROOT/app.out"
status=0
python3 "$HERE/ibus/driver.py" "$ROOT/app.log" >"$TRANSCRIPT" || status=$?
if [[ $status != 0 ]]; then
  for file in daemon app shell; do printf '%s\n' "--- $file" >&2; cat "$ROOT/$file.out" >&2; done
fi
exit "$status"
EOF

env -i PATH="$PATH" HOME="$root/home" XDG_CONFIG_HOME="$root/config" XDG_CACHE_HOME="$root/cache" \
  XDG_RUNTIME_DIR="$root/run" LANG="$locale" LC_ALL="$locale" \
  ${LD_LIBRARY_PATH:+LD_LIBRARY_PATH="$LD_LIBRARY_PATH"} ${GI_TYPELIB_PATH:+GI_TYPELIB_PATH="$GI_TYPELIB_PATH"} \
  IBUS_ADDRESS="unix:path=$root/ibus.socket" IBUS_COMPONENT_PATH="$root/components" \
  SNIPPETS_IBUS_TEST_COMPOSE="$compose" ROOT="$root" HERE="$here" DAEMON="$daemon" \
  PYTHONHOME_FOR_APP="$pythonhome" TRANSCRIPT="$transcript" \
  dbus-run-session -- bash "$root/session.sh"
printf '%s\n' 'ibus engine live: ok'
