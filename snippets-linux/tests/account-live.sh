#!/usr/bin/env bash
# Explicit native account acceptance with an isolated bus, keyring and data root.
# This shares only the compositor, never the login keyring or library.
set -euo pipefail
if [[ ${1:-} == --in-bus ]]; then
  test_binary=$2
  fixture_root=$3
  test_name=$4
  export SNIPPETS_SECRET_TEST_BUS=$DBUS_SESSION_BUS_ADDRESS
  export SNIPPETS_SECRET_TEST_ROOT=$XDG_DATA_HOME/snippets
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
  G_DEBUG=fatal-warnings "$test_binary" --exact "$test_name" --ignored --test-threads=1
  exit
fi
if [[ $# -lt 1 || $# -gt 2 || ! -x $1 || -z ${XDG_RUNTIME_DIR:-} ||
      -z ${HYPRLAND_INSTANCE_SIGNATURE:-} || -z ${WAYLAND_DISPLAY:-} ]]; then
  printf '%s\n' 'Usage: account-live.sh /path/to/library-test-binary [--creation|--automatic-sync|--automatic-reader|--vault-sync|--sync-review|--current-review-keep|--current-review-delete|--nested-review-keep|--nested-review-delete|--nested-journal-keep|--nested-journal-delete|--prior-child-keep-parent-keep|--prior-child-keep-parent-delete|--prior-child-delete-parent-keep|--prior-child-delete-parent-delete] (in the unlocked desktop session)' >&2
  exit 2
fi
case ${2:-} in
  '') test_name=account_ui::live_tests::live_account_onboarding_and_recovery ;;
  --creation) test_name=account_ui::live_tests::creation::live_library_creation_retains_receipts_and_current_library ;;
  --automatic-sync) test_name=account_ui::live_tests::live_automatic_sync ;;
  --automatic-reader) test_name=account_ui::live_tests::live_automatic_reader ;;
  --vault-sync) test_name=account_ui::live_tests::vault::live_manual_and_vault_sync ;;
  --sync-review) test_name=account_ui::live_tests::vault::review::live_secure_conflict_and_deletion ;;
  --current-review-keep) test_name=account_ui::live_tests::vault::review::current::live_current_carrier_keep ;;
  --current-review-delete) test_name=account_ui::live_tests::vault::review::current::live_current_carrier_delete ;;
  --nested-review-keep) test_name=account_ui::live_tests::vault::review::current::nested::live_nested_current_keep ;;
  --nested-review-delete) test_name=account_ui::live_tests::vault::review::current::nested::live_nested_current_delete ;;
  --nested-journal-keep) test_name=account_ui::live_tests::vault::review::current::nested::live_nested_journal_keep ;;
  --nested-journal-delete) test_name=account_ui::live_tests::vault::review::current::nested::live_nested_journal_delete ;;
  --prior-child-keep-parent-keep) test_name=account_ui::live_tests::vault::review::current::prior_child::live_prior_child_keep_parent_keep ;;
  --prior-child-keep-parent-delete) test_name=account_ui::live_tests::vault::review::current::prior_child::live_prior_child_keep_parent_delete ;;
  --prior-child-delete-parent-keep) test_name=account_ui::live_tests::vault::review::current::prior_child::live_prior_child_delete_parent_keep ;;
  --prior-child-delete-parent-delete) test_name=account_ui::live_tests::vault::review::current::prior_child::live_prior_child_delete_parent_delete ;;
  *) printf '%s\n' 'Unknown native account fixture.' >&2; exit 2 ;;
esac
if ! "$1" --list | rg -Fx "$test_name: test" > /dev/null; then
  printf '%s\n' 'The selected test binary does not contain the live fixture.' >&2
  exit 2
fi
host_runtime=$XDG_RUNTIME_DIR
if [[ $WAYLAND_DISPLAY != /* ]]; then
  export WAYLAND_DISPLAY=$host_runtime/$WAYLAND_DISPLAY
fi
if [[ ! -S $WAYLAND_DISPLAY || ! -d $host_runtime/hypr ]]; then
  printf '%s\n' 'The selected desktop compositor is unavailable.' >&2
  exit 1
fi
fixture_root=$(mktemp -d /tmp/snippets-account.XXXXXXXX)
# Short path keeps Hyprland's signature/socket pathname within sockaddr_un.
fixture_runtime=$(mktemp -d /tmp/sh.XXXXXX)
trap 'rm -rf -- "$fixture_root" "$fixture_runtime"' EXIT
mkdir -m 700 "$fixture_root/data" "$fixture_root/control"
ln -s -- "$host_runtime/hypr" "$fixture_runtime/hypr"
# No activation directories: GTK must not start portals, document mounts or
# accessibility services on behalf of this deliberately incomplete test session.
cat > "$fixture_root/bus.conf" <<XML
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
export XDG_DATA_HOME=$fixture_root/data
export XDG_RUNTIME_DIR=$fixture_runtime
export GIO_USE_VFS=local
export GDK_DEBUG=no-portals
export GTK_A11Y=none
export SNIPPETS_SECRET_HOST_BUS=${DBUS_SESSION_BUS_ADDRESS:-}
dbus-run-session --config-file="$fixture_root/bus.conf" -- \
  bash "$0" --in-bus "$1" "$fixture_root" "$test_name"
