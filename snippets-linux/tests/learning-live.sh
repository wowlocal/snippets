#!/usr/bin/env bash
# Existing local-learning acceptance: mapped GTK controls on an isolated bus.
set -euo pipefail
if [[ ${1:-} == --in-bus ]]; then
  [[ $DBUS_SESSION_BUS_ADDRESS != "$SNIPPETS_LEARNING_HOST_BUS" ]]
  export SNIPPETS_LEARNING_LIVE=public-private-roots
  G_DEBUG=fatal-warnings "$2" --exact \
    ui::usage_settings::tests::native_learning_settings_picker_order_and_independent_resets \
    --ignored --test-threads=1 --nocapture
  exit
fi
if [[ $# != 1 || ! -x $1 || -z ${XDG_RUNTIME_DIR:-} ||
      -z ${DBUS_SESSION_BUS_ADDRESS:-} || -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ||
      -z ${WAYLAND_DISPLAY:-} ]]; then
  printf '%s\n' 'Usage: learning-live.sh /path/to/library-test-binary (unlocked Omarchy)' >&2
  exit 2
fi
"$1" --list | rg -Fx 'ui::usage_settings::tests::native_learning_settings_picker_order_and_independent_resets: test' > /dev/null
fixture_root=$(mktemp -d /tmp/snippets-learning-runtime.XXXXXXXX)
fixture_runtime=$(mktemp -d /tmp/sl.XXXXXX)
trap 'rm -rf -- "$fixture_root" "$fixture_runtime"' EXIT
host_runtime=$XDG_RUNTIME_DIR
if [[ $WAYLAND_DISPLAY != /* ]]; then
  export WAYLAND_DISPLAY=$host_runtime/$WAYLAND_DISPLAY
fi
[[ -S $WAYLAND_DISPLAY && -d $host_runtime/hypr ]]
mkdir -m 700 "$fixture_root/config" "$fixture_root/data" "$fixture_root/cache" "$fixture_root/services"
# Keep the inherited Hyprland socket pathname below the Unix socket length limit.
ln -s -- "$host_runtime/hypr" "$fixture_runtime/hypr"
cat > "$fixture_root/bus.conf" <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=$fixture_runtime</listen>
  <auth>EXTERNAL</auth>
  <servicedir>$fixture_root/services</servicedir>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
XML
export SNIPPETS_LEARNING_HOST_BUS=$DBUS_SESSION_BUS_ADDRESS
export XDG_CONFIG_HOME=$fixture_root/config XDG_DATA_HOME=$fixture_root/data
export XDG_CACHE_HOME=$fixture_root/cache XDG_RUNTIME_DIR=$fixture_runtime
export GSETTINGS_BACKEND=memory GDK_BACKEND=wayland GDK_DEBUG=no-portals
export GIO_USE_VFS=local GTK_A11Y=none
unset SNIPPETS_SUPPORT_DIR SNIPPETS_USAGE_DISABLED AT_SPI_BUS_ADDRESS GTK_USE_PORTAL
dbus-run-session --config-file="$fixture_root/bus.conf" -- bash "$0" --in-bus "$1"
