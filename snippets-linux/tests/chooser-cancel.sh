#!/usr/bin/env bash
# Defect-only diagnostic. Shares Wayland, owns all data, D-Bus, keyring and a11y.
set -euo pipefail
TASK_REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ ${1:-} == --in-bus ]]; then
  TASK_MODE=$2 TASK_FIXTURE=$3 TASK_POLICY=$4
  [[ $DBUS_SESSION_BUS_ADDRESS != "$SNIPPETS_SECRET_HOST_BUS" ]]
  if [[ $TASK_POLICY == fatal ]]; then export G_DEBUG=fatal-warnings; else unset G_DEBUG; fi
  if [[ $TASK_MODE == minimal ]]; then
    exec "$TASK_FIXTURE/gtk-chooser-cancel"
  fi
  TASK_HARNESS=$5 TASK_APP=$6
  TASK_REGISTRY= TASK_KEYRING= TASK_PRIMARY=
  cleanup_owned() {
    [[ ! -f $TASK_FIXTURE/app.log ]] || cat "$TASK_FIXTURE/app.log"
    for TASK_PID in "$TASK_PRIMARY" "$TASK_KEYRING" "$TASK_REGISTRY"; do
      if [[ -n $TASK_PID ]]; then kill "$TASK_PID" 2>/dev/null || true; wait "$TASK_PID" 2>/dev/null || true; fi
    done
  }
  trap cleanup_owned EXIT
  printf '%s' 'Public fictional keyring fixture password' |
    gnome-keyring-daemon --foreground --components=secrets --unlock \
      --control-directory="$TASK_FIXTURE/control" >"$TASK_FIXTURE/keyring.log" 2>&1 &
  TASK_KEYRING=$!
  for ((TASK_TRY=0; TASK_TRY<50; TASK_TRY++)); do
    if gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.NameHasOwner org.freedesktop.secrets | rg -q true; then break; fi
    sleep 0.1
  done
  TASK_ADDRESS=$(gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress)
  TASK_PATTERN="^\('([^']+)',\)$"
  [[ $TASK_ADDRESS =~ $TASK_PATTERN ]]
  export AT_SPI_BUS_ADDRESS=${BASH_REMATCH[1]}
  DBUS_STARTER_ADDRESS=$AT_SPI_BUS_ADDRESS DBUS_STARTER_BUS_TYPE=accessibility \
    /usr/lib/at-spi2-registryd >"$TASK_FIXTURE/registry.log" 2>&1 &
  TASK_REGISTRY=$!
  export SNIPPETS_SECRET_TEST_ROOT=$XDG_DATA_HOME/snippets
  TASK_TEST=$("$TASK_HARNESS" --list | sed -n 's/: test$//p' | rg '::prepare_installed_chooser_cancel_fixture$')
  [[ -n $TASK_TEST && $TASK_TEST != *$'\n'* ]]
  "$TASK_HARNESS" --exact "$TASK_TEST" --ignored --test-threads=1 --nocapture
  TASK_ROOT=$XDG_DATA_HOME/snippets
  hash_primary() {
    (cd -- "$TASK_ROOT"; rg --files --hidden -g snippets.json -g secret-owner.bin -g 'Vault/**' -g 'Sync/**' |
      sort | while IFS= read -r TASK_FILE; do sha256sum -- "$TASK_FILE"; done)
  }
  hash_primary >"$TASK_FIXTURE/before.sha256"
  "$TASK_APP" >"$TASK_FIXTURE/app.log" 2>&1 &
  TASK_PRIMARY=$!
  TASK_READY=false
  for ((TASK_TRY=0; TASK_TRY<80; TASK_TRY++)); do
    if gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.NameHasOwner com.khm.snippets.linux | rg -q true; then TASK_READY=true; break; fi
    kill -0 "$TASK_PRIMARY"; sleep 0.1
  done
  [[ $TASK_READY == true ]]
  gdbus call --session --dest com.khm.snippets.linux --object-path /com/khm/snippets/linux \
    --method org.gtk.Actions.Activate account '[]' '{}' >/dev/null
  press_owned() {
    local TASK_LABEL=$1 TASK_PRESSED=false
    for ((TASK_TRY=0; TASK_TRY<100; TASK_TRY++)); do
      kill -0 "$TASK_PRIMARY"
      hyprctl -j locked | jq -e '.locked == false' >/dev/null
      if hyprctl -j activewindow | jq -e --argjson pid "$TASK_PRIMARY" '.pid == $pid' >/dev/null &&
        "$TASK_FIXTURE/chooser-cancel-atspi" "$TASK_PRIMARY" "$TASK_LABEL"; then TASK_PRESSED=true; break; fi
      sleep 0.05
    done
    [[ $TASK_PRESSED == true ]]
  }
  press_owned 'Library Recovery History…'
  press_owned 'Review…'
  press_owned 'Choose Several Vault Files…'
  TASK_MAPPED=false
  for ((TASK_TRY=0; TASK_TRY<100; TASK_TRY++)); do
    kill -0 "$TASK_PRIMARY"
    hyprctl -j locked | jq -e '.locked == false' >/dev/null
    if hyprctl -j activewindow | jq -e --argjson pid "$TASK_PRIMARY" '.pid == $pid and .title == "Choose Previous Vault File"' >/dev/null; then TASK_MAPPED=true; break; fi
    sleep 0.05
  done
  [[ $TASK_MAPPED == true ]]
  key_owned() {
    local TASK_MODS=$1 TASK_KEY=$2 TASK_WINDOW
    hyprctl -j locked | jq -e '.locked == false' >/dev/null
    TASK_WINDOW=$(hyprctl -j activewindow | jq -er --argjson pid "$TASK_PRIMARY" \
      'select(.pid == $pid and .title == "Choose Previous Vault File") | .address | select(test("^0x[0-9a-fA-F]+$"))')
    hyprctl eval "assert(hl.dispatch(hl.dsp.send_key_state({ mods = \"$TASK_MODS\", key = \"$TASK_KEY\", window = \"address:$TASK_WINDOW\", state = \"down\" })).ok) hl.timer(function() hl.dispatch(hl.dsp.send_key_state({ mods = \"$TASK_MODS\", key = \"$TASK_KEY\", window = \"address:$TASK_WINDOW\", state = \"up\" })) end, { timeout = 50, type = \"oneshot\" })" >/dev/null
  }
  if [[ -n ${SNIPPETS_CHOOSER_PUBLIC_FOLDER:-} ]]; then
    key_owned CTRL l
    press_owned public-folder
    key_owned '' Return
  fi
  press_owned Cancel
  printf '%s\n' 'Installed production multiple-file chooser: actual Cancel button activated.'
  # Observe callbacks after cancellation; no wait is inserted before Cancel.
  sleep 2
  if ! kill -0 "$TASK_PRIMARY" 2>/dev/null; then
    TASK_EXIT=0; wait "$TASK_PRIMARY" || TASK_EXIT=$?; TASK_PRIMARY=
    hash_primary >"$TASK_FIXTURE/after.sha256"
    cmp "$TASK_FIXTURE/before.sha256" "$TASK_FIXTURE/after.sha256"
    printf 'installed_survived=0 primary_history_vault_unchanged=1 exit=%d\n' "$TASK_EXIT"
    exit "$TASK_EXIT"
  fi
  TASK_FOCUS=false
  if hyprctl -j activewindow | jq -e --argjson pid "$TASK_PRIMARY" '.pid == $pid and .title == "Account & Recovery"' >/dev/null; then TASK_FOCUS=true; fi
  hyprctl -j clients | jq -e --argjson pid "$TASK_PRIMARY" 'all(.[]; .pid != $pid or .title != "Choose Previous Vault File")' >/dev/null
  gdbus call --session --dest com.khm.snippets.linux --object-path /com/khm/snippets/linux \
    --method org.gtk.Actions.Activate quit '[]' '{}' >/dev/null
  wait "$TASK_PRIMARY"; TASK_PRIMARY=
  hash_primary >"$TASK_FIXTURE/after.sha256"
  cmp "$TASK_FIXTURE/before.sha256" "$TASK_FIXTURE/after.sha256"
  printf 'installed_survived=1 focus_returned=%s primary_history_vault_unchanged=1\n' "$TASK_FOCUS"
  exit
fi

TASK_MODE=${1:-} TASK_POLICY=fatal TASK_INFLIGHT=false
case "$TASK_MODE" in
  minimal) TASK_HARNESS= TASK_APP=; shift ;;
  installed) [[ $# -ge 3 && -x $2 && -x $3 ]]; TASK_HARNESS=$(realpath -- "$2"); TASK_APP=$(realpath -- "$3"); shift 3 ;;
  *) echo 'Usage: chooser-cancel.sh minimal | installed TEST_HARNESS INSTALLED_APP [--nonfatal] [--inflight-folder]' >&2; exit 2 ;;
esac
for TASK_OPTION in "$@"; do
  case "$TASK_OPTION" in --nonfatal) TASK_POLICY=normal ;; --inflight-folder) TASK_INFLIGHT=true ;; *) exit 2 ;; esac
done
hyprctl -j locked | jq -e '.locked == false' >/dev/null
TASK_HOST_RUNTIME=$XDG_RUNTIME_DIR
TASK_WAYLAND=$WAYLAND_DISPLAY
[[ $TASK_WAYLAND = /* ]] || TASK_WAYLAND=$TASK_HOST_RUNTIME/$TASK_WAYLAND
[[ -S $TASK_WAYLAND && -d $TASK_HOST_RUNTIME/hypr && -n $DBUS_SESSION_BUS_ADDRESS ]]
TASK_FIXTURE=$(mktemp -d /tmp/snippets-chooser-cancel.XXXXXXXX)
TASK_RUNTIME=$(mktemp -d /tmp/scc.XXXXXX)
trap 'rm -rf -- "$TASK_FIXTURE" "$TASK_RUNTIME"' EXIT
mkdir -m 700 "$TASK_FIXTURE/"{config,data,cache,home,control,services}
unset SNIPPETS_CHOOSER_PUBLIC_FOLDER
if [[ $TASK_INFLIGHT == true ]]; then
  TASK_FOLDER=$TASK_FIXTURE/home
  for ((TASK_DEPTH=0; TASK_DEPTH<128; TASK_DEPTH++)); do TASK_FOLDER=$TASK_FOLDER/d; mkdir -m 700 "$TASK_FOLDER"; done
  export SNIPPETS_CHOOSER_PUBLIC_FOLDER=$TASK_FOLDER
fi
ln -s -- "$TASK_HOST_RUNTIME/hypr" "$TASK_RUNTIME/hypr"
TASK_SERVICE_XML=
if [[ $TASK_MODE == installed ]]; then
  cc -Wall -Wextra -Werror "$TASK_REPO/snippets-linux/tests/reference/chooser-cancel-atspi.c" \
    -o "$TASK_FIXTURE/chooser-cancel-atspi" $(pkg-config --cflags --libs atspi-2 gobject-2.0)
  cat >"$TASK_FIXTURE/services/org.a11y.Bus.service" <<'SERVICE'
[D-BUS Service]
Name=org.a11y.Bus
Exec=/usr/lib/at-spi-bus-launcher
SERVICE
  TASK_SERVICE_XML="<servicedir>$TASK_FIXTURE/services</servicedir>"
else
  cc -Wall -Wextra -Werror -Wno-deprecated-declarations \
    "$TASK_REPO/snippets-linux/tests/reference/gtk-chooser-cancel.c" \
    -o "$TASK_FIXTURE/gtk-chooser-cancel" $(pkg-config --cflags --libs gtk4)
fi
cat >"$TASK_FIXTURE/bus.conf" <<XML
<busconfig><type>session</type><listen>unix:tmpdir=$TASK_RUNTIME</listen><auth>EXTERNAL</auth>
$TASK_SERVICE_XML
<policy context="default"><allow user="$UID"/><allow own="*"/><allow send_destination="*"/><allow receive_sender="*"/></policy></busconfig>
XML
export SNIPPETS_SECRET_HOST_BUS=$DBUS_SESSION_BUS_ADDRESS
export XDG_DATA_HOME=$TASK_FIXTURE/data XDG_CONFIG_HOME=$TASK_FIXTURE/config
export XDG_CACHE_HOME=$TASK_FIXTURE/cache XDG_RUNTIME_DIR=$TASK_RUNTIME
export WAYLAND_DISPLAY=$TASK_WAYLAND GDK_BACKEND=wayland GDK_DEBUG=no-portals
export GSETTINGS_BACKEND=memory GIO_USE_VFS=local
export GTK_A11Y=none
[[ $TASK_MODE != installed ]] || export GTK_A11Y=atspi
unset SNIPPETS_SUPPORT_DIR AT_SPI_BUS_ADDRESS GTK_USE_PORTAL
dbus-run-session --config-file="$TASK_FIXTURE/bus.conf" -- \
  bash "$0" --in-bus "$TASK_MODE" "$TASK_FIXTURE" "$TASK_POLICY" "$TASK_HARNESS" "$TASK_APP"
