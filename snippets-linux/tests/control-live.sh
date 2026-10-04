#!/usr/bin/env bash
# Real installed app/CLI, private bus and AT-SPI registry, public fictional data.
set -euo pipefail
if [[ ${1:-} == --in-bus ]]; then
  test_binary=$2
  release_directory=$3
  fixture_root=$4
  fixture_test=$5
  [[ $DBUS_SESSION_BUS_ADDRESS != "$SNIPPETS_CONTROL_HOST_BUS" ]]
  fixture_a11y_response=$(gdbus call --session --dest org.a11y.Bus \
    --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress)
  fixture_a11y_pattern="^\('([^']+)',\)$"
  [[ $fixture_a11y_response =~ $fixture_a11y_pattern ]]
  fixture_a11y_address=${BASH_REMATCH[1]}
  export AT_SPI_BUS_ADDRESS=$fixture_a11y_address
  # The distro accessibility broker expects a user manager for activation.
  # Start only our registry directly, without changing any host service.
  AT_SPI_BUS_ADDRESS=$fixture_a11y_address \
    DBUS_STARTER_ADDRESS=$fixture_a11y_address DBUS_STARTER_BUS_TYPE=accessibility \
    /usr/lib/at-spi2-registryd >"$fixture_root/registry.log" 2>&1 &
  fixture_registry=$!
  trap 'kill "$fixture_registry" 2>/dev/null || true; wait "$fixture_registry" 2>/dev/null || true' EXIT
  fixture_ready=false
  for ((attempt=0; attempt<50; attempt++)); do
    if gdbus call --address "$fixture_a11y_address" --dest org.freedesktop.DBus \
      --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner \
      org.a11y.atspi.Registry 2>/dev/null | rg -q true; then
      fixture_ready=true
      break
    fi
    sleep 0.1
  done
  [[ $fixture_ready == true ]]
  export SNIPPETS_CONTROL_LIVE=public-private-roots
  export SNIPPETS_CONTROL_TEST_RELEASE=$release_directory
  G_DEBUG=fatal-warnings "$test_binary" --exact \
    "$fixture_test" \
    --ignored --test-threads=1 --nocapture
  exit
fi
if [[ $# -lt 2 || $# -gt 3 || ! -x $1 || ! -d $2 || -z ${XDG_RUNTIME_DIR:-} ||
      -z ${DBUS_SESSION_BUS_ADDRESS:-} || -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ||
      -z ${WAYLAND_DISPLAY:-} ]]; then
  printf '%s\n' 'Usage: control-live.sh /path/to/library-test-binary /absolute/path/to/release-directory [unlocked-editor|secure-editor|secure-recovery|secure-setup] (unlocked Omarchy)' >&2
  exit 2
fi
case ${3:-} in
  '') fixture_test=control_ui::live_tests::live_installed_cli_secure_create_and_reveal ;;
  unlocked-editor) fixture_test=control_ui::live_tests::live_installed_cli_does_not_borrow_unlocked_editor ;;
  secure-editor) fixture_test=control_ui::live_tests::live_installed_secure_editor_edit_and_passphrase ;;
  secure-recovery) fixture_test=control_ui::live_tests::live_installed_secure_recovery_and_revocation ;;
  secure-setup) fixture_test=control_ui::live_tests::live_installed_secure_setup_and_recovery_sheet ;;
  *) exit 2 ;;
esac
if [[ ${3:-} == secure-setup ]]; then
  command -v grim >/dev/null
  command -v tesseract >/dev/null
fi
for binary in snippets snippets-cli snippets-owner-auth; do
  [[ -x $2/$binary ]]
done
"$1" --list | rg -Fx "$fixture_test: test" > /dev/null
fixture_root=$(mktemp -d /tmp/snippets-control-runtime.XXXXXXXX)
fixture_runtime=$(mktemp -d /tmp/sc.XXXXXX)
trap 'rm -rf -- "$fixture_root" "$fixture_runtime"' EXIT
host_runtime=$XDG_RUNTIME_DIR
if [[ $WAYLAND_DISPLAY != /* ]]; then
  export WAYLAND_DISPLAY=$host_runtime/$WAYLAND_DISPLAY
fi
[[ -S $WAYLAND_DISPLAY && -d $host_runtime/hypr ]]
ln -s -- "$host_runtime/hypr" "$fixture_runtime/hypr"
mkdir -m 700 "$fixture_root/config" "$fixture_root/data" "$fixture_root/cache" "$fixture_root/services"
# Accessibility is the only activatable service. No keyring, portals, document
# mounts or user-manager activation are inherited from the host session.
cat > "$fixture_root/services/org.a11y.Bus.service" <<'SERVICE'
[D-BUS Service]
Name=org.a11y.Bus
Exec=/usr/lib/at-spi-bus-launcher
SERVICE
cat > "$fixture_root/bus.conf" <<XML
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=$fixture_runtime</listen>
  <auth>EXTERNAL</auth>
  <servicedir>$fixture_root/services</servicedir>
  <policy context="default">
    <allow user="$UID"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
XML
export SNIPPETS_CONTROL_HOST_BUS=$DBUS_SESSION_BUS_ADDRESS
export XDG_CONFIG_HOME=$fixture_root/config XDG_DATA_HOME=$fixture_root/data
export XDG_CACHE_HOME=$fixture_root/cache XDG_RUNTIME_DIR=$fixture_runtime
export GSETTINGS_BACKEND=memory GDK_BACKEND=wayland GDK_DEBUG=no-portals
export GIO_USE_VFS=local GTK_A11Y=atspi
unset SNIPPETS_SUPPORT_DIR AT_SPI_BUS_ADDRESS GTK_USE_PORTAL
dbus-run-session --config-file="$fixture_root/bus.conf" -- \
  bash "$0" --in-bus "$1" "$2" "$fixture_root" "$fixture_test"
