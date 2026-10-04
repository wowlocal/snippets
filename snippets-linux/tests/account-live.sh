#!/usr/bin/env bash
# Explicit native account acceptance with an isolated bus, keyring and data root.
# Shares the compositor and optionally real OpenFile only, never the login keyring or library.
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
  printf '%s\n' 'Usage: account-live.sh /path/to/library-test-binary [--creation|--switch|--restoration|--secure-restoration|--foreign-restoration|--file-restoration|--backup-file-restoration|--mixed-retained-restoration|--mixed-files-restoration|--mixed-backup-restoration|--portal-chooser|--portal-file-restoration|--portal-backup-file-restoration|--portal-mixed-retained-restoration|--portal-mixed-files-restoration|--portal-mixed-backup-restoration|--restore-cancel-consent|--restore-cancel-baseline|--restore-finish-ordinary|--restore-process-ordinary|--history-maintenance|--restore-finish-vault|--pairing|--recovery-reconcile|--recovery-retry|--automatic-sync|--automatic-reader|--vault-sync|--sync-review|--current-review-keep|--current-review-delete|--nested-review-keep|--nested-review-delete|--nested-journal-keep|--nested-journal-delete|--prior-child-keep-parent-keep|--prior-child-keep-parent-delete|--prior-child-delete-parent-keep|--prior-child-delete-parent-delete] (in the unlocked desktop session)' >&2
  exit 2
fi
portal_mode=false
case ${2:-} in
  --portal-chooser|--portal-file-restoration|--portal-backup-file-restoration|--portal-mixed-retained-restoration|--portal-mixed-files-restoration|--portal-mixed-backup-restoration)
    portal_mode=true
    set -- "$1" "${2/--portal-/--}"
    ;;
esac
case ${2:-} in
  --chooser) test_name=account_ui::live_tests::portal::live_host_filechooser_smoke ;;
  '') test_name=account_ui::live_tests::live_account_onboarding_and_recovery ;;
  --creation) test_name=account_ui::live_tests::creation::live_library_creation_retains_receipts_and_current_library ;;
  --switch) test_name=account_ui::live_tests::switching::live_reviewed_library_switch_keeps_source_history_and_reconnects ;;
  --restoration) test_name=account_ui::live_tests::restoration_live::live_saved_history_restoration_preserves_current_versions ;;
  --secure-restoration) test_name=account_ui::live_tests::secure_restoration_live::live_secure_saved_history_restoration ;;
  --foreign-restoration) test_name=account_ui::live_tests::secure_restoration_live::live_retained_foreign_vault_history_restoration ;;
  --file-restoration) test_name=account_ui::live_tests::secure_restoration_live::live_external_json_vault_history_restoration ;;
  --backup-file-restoration) test_name=account_ui::live_tests::secure_restoration_live::live_external_backup_vault_history_restoration ;;
  --mixed-retained-restoration) test_name=account_ui::live_tests::secure_restoration_live::mixed::live_mixed_retained_json_vault_history_restoration ;;
  --mixed-files-restoration) test_name=account_ui::live_tests::secure_restoration_live::mixed::live_mixed_json_files_vault_history_restoration ;;
  --mixed-backup-restoration) test_name=account_ui::live_tests::secure_restoration_live::mixed::live_mixed_json_backup_vault_history_restoration ;;
  --restore-cancel-consent) test_name=account_ui::live_tests::secure_restoration_live::live_restoration_cancel_after_consent ;;
  --restore-cancel-baseline) test_name=account_ui::live_tests::secure_restoration_live::live_restoration_cancel_after_baseline ;;
  --restore-finish-ordinary) test_name=account_ui::live_tests::secure_restoration_live::live_restoration_finish_after_ordinary ;;
  --restore-process-ordinary) test_name=key_store::handover::tests::restoration::foreign::desktop_workflow::process_death::native_restoration_process_kill_and_offline_resume ;;
  --history-maintenance) test_name=account_ui::history_view::tests::native_history_cleanup_controls_respect_saved_consent_and_empty_key_state ;;
  --restore-finish-vault) test_name=account_ui::live_tests::secure_restoration_live::live_restoration_finish_after_vault ;;
  --pairing) test_name=account_ui::live_tests::pairing::live_device_pairing_and_signed_approval_restart ;;
  --recovery-reconcile) test_name=account_ui::live_tests::recovery_mutation::live_recovery_replacement_reconciles_lost_reply ;;
  --recovery-retry) test_name=account_ui::live_tests::recovery_mutation::live_recovery_replacement_replays_original_proof ;;
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
mkdir -m 700 "$fixture_root/data" "$fixture_root/control" "$fixture_root/config" "$fixture_root/cache"
ln -s -- "$host_runtime/hypr" "$fixture_runtime/hypr"
# GTK 4.22 discovers portals through ListActivatableNames. Advertise only the
# already-owned narrow relay; activation fails closed if that relay is absent.
# No host activation directories, document mounts or accessibility services.
portal_service_xml=""
if [[ $portal_mode == true ]]; then
  mkdir -m 700 "$fixture_root/portal-services"
  cat > "$fixture_root/portal-services/org.freedesktop.portal.Desktop.service" <<SERVICE
[D-BUS Service]
Name=org.freedesktop.portal.Desktop
Exec=/usr/bin/false
SERVICE
  portal_service_xml="<servicedir>$fixture_root/portal-services</servicedir>"
fi
cat > "$fixture_root/bus.conf" <<XML
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=$fixture_runtime</listen>
  <auth>EXTERNAL</auth>
  $portal_service_xml
  <policy context="default">
    <allow user="$UID"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
XML
export XDG_DATA_HOME=$fixture_root/data
export XDG_CONFIG_HOME=$fixture_root/config
export XDG_CACHE_HOME=$fixture_root/cache
export GSETTINGS_BACKEND=memory
export XDG_RUNTIME_DIR=$fixture_runtime
export GIO_USE_VFS=local
unset GTK_USE_PORTAL SNIPPETS_ACCOUNT_PORTAL
if [[ $portal_mode == true ]]; then
  unset GDK_DEBUG
  export SNIPPETS_ACCOUNT_PORTAL=real-host-open-file
else
  export GDK_DEBUG=no-portals
fi
export GTK_A11Y=none
export SNIPPETS_SECRET_HOST_BUS=${DBUS_SESSION_BUS_ADDRESS:-}
dbus-run-session --config-file="$fixture_root/bus.conf" -- \
  bash "$0" --in-bus "$1" "$fixture_root" "$test_name"
