#!/usr/bin/env bash
# Multi-process Git sync integration test: macOS and iOS app-hosted tests take turns
# on one disposable repository served by the real `git http-backend` on loopback.
#
#   scripts/test-git-sync-integration.sh            # build, then run every phase
#   SKIP_BUILD=1 scripts/test-git-sync-integration.sh
#   SNIPPETS_GIT_E2E_IOS_UDID=<udid> scripts/test-git-sync-integration.sh
#   SKIP_SSH=1 / SKIP_UI=1 leave out those stages.
#
# HTTPS phases: mac-create (new library + recovery code) → ios-join (recovery code,
# edits) → mac-join (fresh install, recovery code, deletion) → ios-verify → mac-rotate
# (replaces the library's keys, new recovery code) → ios-rotated (the old code is
# refused, the new one opens everything).
# SSH phases, through a throwaway loopback sshd that only runs git services inside this
# run's directory: mac-ssh-create (system ssh, key held only by a private ssh-agent) →
# ios-ssh-join (SwiftNIO SSH, device key, host key confirmed by fingerprint) →
# mac-ssh-verify. Nothing reads or changes the user's own ssh configuration, keys or
# agent.
# Each platform also adds a secure snippet that the other must open with nothing but
# the recovery code (the vault key travels in keys/vault.json).
# Afterwards each bare repository itself is checked: record count, key envelopes,
# fixed commit authorship, and no plaintext marker anywhere in its history.
set -euo pipefail
umask 077

CLIENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAC_CONFIG="/tmp/snippets-git-sync-e2e-macos.json"
MAC_DERIVED="${SNIPPETS_MACOS_DERIVED:-/tmp/snippets-macos-derived}"
IOS_DERIVED="${SNIPPETS_IOS_DERIVED:-/tmp/snippets-ios-derived}"
IOS_UDID="${SNIPPETS_GIT_E2E_IOS_UDID:-}"
IOS_BOOTED_HERE=0
SERVER_PID=""
SSHD_PID=""
AGENT_PID=""
AGENT_SOCK=""
SSH_CONFIG=""
MAC_CONFIG_OWNED=0

for executable in python3 xcodebuild xcrun openssl git ssh-keygen; do
  command -v "$executable" >/dev/null || { echo "missing executable: $executable" >&2; exit 1; }
done
if [[ -e "$MAC_CONFIG" ]]; then
  echo "refusing to overwrite an existing macOS configuration: $MAC_CONFIG" >&2
  exit 1
fi

RUN_ROOT="$(mktemp -d /tmp/snippets-git-e2e.XXXXXX)"
REPOS="$RUN_ROOT/repos"
BARE="$REPOS/library.git"
mkdir -p "$REPOS"

cleanup() {
  set +e
  [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" >/dev/null 2>&1
  [[ -z "$SSHD_PID" ]] || kill "$SSHD_PID" >/dev/null 2>&1
  [[ -z "$AGENT_PID" ]] || kill "$AGENT_PID" >/dev/null 2>&1
  [[ -z "$AGENT_SOCK" ]] || rm -f -- "$AGENT_SOCK"
  [[ "$MAC_CONFIG_OWNED" == 1 ]] && rm -f -- "$MAC_CONFIG"
  if [[ -n "$IOS_UDID" ]]; then
    for name in SNIPPETS_GIT_E2E SNIPPETS_GIT_E2E_URL SNIPPETS_GIT_E2E_USERNAME \
      SNIPPETS_GIT_E2E_TOKEN SNIPPETS_GIT_E2E_PHASE SNIPPETS_GIT_E2E_RECOVERY_CODE \
      SNIPPETS_GIT_E2E_PREVIOUS_CODE \
      SNIPPETS_GIT_E2E_SSH_DEVICE_KEY SNIPPETS_GIT_E2E_SSH_HOST_FINGERPRINT; do
      xcrun simctl spawn "$IOS_UDID" launchctl unsetenv "$name" >/dev/null 2>&1
    done
    [[ "$IOS_BOOTED_HERE" == 1 ]] && xcrun simctl shutdown "$IOS_UDID" >/dev/null 2>&1
  fi
  [[ "$RUN_ROOT" == /tmp/snippets-git-e2e.* ]] && rm -rf -- "$RUN_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

git init --quiet --bare --initial-branch=main "$BARE"
USERNAME="tester"
openssl rand -hex 20 > "$RUN_ROOT/token"
TOKEN="$(cat "$RUN_ROOT/token")"

python3 -I "$CLIENT_DIR/scripts/git-http-test-server.py" --root "$REPOS" --username "$USERNAME" \
  --token-file "$RUN_ROOT/token" --log "$RUN_ROOT/requests.log" > "$RUN_ROOT/server.out" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  grep -q '^READY ' "$RUN_ROOT/server.out" 2>/dev/null && break
  sleep 0.2
done
PORT="$(awk '/^READY /{print $2}' "$RUN_ROOT/server.out")"
[[ -n "$PORT" ]] || { echo "git test server did not start" >&2; cat "$RUN_ROOT/server.out" >&2; exit 1; }
URL="http://127.0.0.1:$PORT/library.git"
echo "git test server: $URL"

if [[ -z "$IOS_UDID" ]]; then
  # Reuse an existing, idle iPhone on the newest runtime; never claim one in use.
  IOS_UDID="$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
runtimes = sorted((k for k in devices if "iOS" in k), key=lambda k: [int(p) for p in k.rsplit("iOS-", 1)[1].split("-")])
for runtime in reversed(runtimes):
    for device in devices[runtime]:
        if device["name"].startswith("iPhone") and device["state"] == "Shutdown":
            print(device["udid"]); sys.exit(0)
')"
fi
[[ -n "$IOS_UDID" ]] || { echo "no idle iPhone simulator found; set SNIPPETS_GIT_E2E_IOS_UDID" >&2; exit 1; }
if ! xcrun simctl list devices | grep "$IOS_UDID" | grep -q Booted; then
  xcrun simctl boot "$IOS_UDID"
  IOS_BOOTED_HERE=1
fi
xcrun simctl bootstatus "$IOS_UDID" -b >/dev/null
echo "iOS simulator: $IOS_UDID"

if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
  echo "Building macOS tests"
  xcodebuild -quiet -project "$CLIENT_DIR/Snippets.xcodeproj" -scheme Snippets \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$MAC_DERIVED" CODE_SIGNING_ALLOWED=NO build-for-testing
  echo "Building iOS tests"
  xcodebuild -quiet -project "$CLIENT_DIR/Snippets.xcodeproj" -scheme 'Snippets iOS' \
    -configuration Debug -destination "platform=iOS Simulator,id=$IOS_UDID" \
    -derivedDataPath "$IOS_DERIVED" CODE_SIGNING_ALLOWED=NO build-for-testing
fi

RECOVERY_CODE=""

run_mac_phase() {
  local phase="$1"
  echo "macOS phase: $phase"
  python3 -I -c 'import json, sys; json.dump({"repositoryURL": sys.argv[1], "username": sys.argv[2],
    "token": sys.argv[3], "phase": sys.argv[4], "recoveryCode": sys.argv[5] or None,
    "handoffPath": sys.argv[6], "sshConfigPath": sys.argv[8] or None,
    "sshAgentSocket": sys.argv[9] or None}, open(sys.argv[7], "w"))' \
    "$URL" "$USERNAME" "$TOKEN" "$phase" "$RECOVERY_CODE" "$RUN_ROOT/handoff.json" "$MAC_CONFIG" \
    "$SSH_CONFIG" "$AGENT_SOCK"
  MAC_CONFIG_OWNED=1
  xcodebuild -project "$CLIENT_DIR/Snippets.xcodeproj" -scheme Snippets \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$MAC_DERIVED" CODE_SIGNING_ALLOWED=NO test-without-building \
    -only-testing:'Snippets macOSTests/GitSyncAppIntegrationTests/testGitSyncPhase' \
    > "$RUN_ROOT/$phase.log" 2>&1 || { tail -40 "$RUN_ROOT/$phase.log" >&2; exit 1; }
  rm -f -- "$MAC_CONFIG"
  require_passed "$phase"
}

# A phase whose configuration did not arrive would skip, and a skip is not a pass.
require_passed() {
  local phase="$1"
  if grep -q "testGitSyncPhase.*skipped" "$RUN_ROOT/$phase.log" \
      || ! grep -q "testGitSyncPhase.*passed" "$RUN_ROOT/$phase.log"; then
    echo "phase $phase did not run to a pass" >&2
    grep -E "testGitSyncPhase|error:|XCTAssert|Skipped|skipped" "$RUN_ROOT/$phase.log" | tail -20 >&2
    exit 1
  fi
  echo "  $phase passed"
}

run_ios_phase() {
  local phase="$1"
  echo "iOS phase: $phase"
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_GIT_E2E 1
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_GIT_E2E_URL "$URL"
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_GIT_E2E_USERNAME "$USERNAME"
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_GIT_E2E_TOKEN "$TOKEN"
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_GIT_E2E_PHASE "$phase"
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_GIT_E2E_RECOVERY_CODE "$RECOVERY_CODE"
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_GIT_E2E_PREVIOUS_CODE "${PREVIOUS_CODE:-}"
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_GIT_E2E_SSH_DEVICE_KEY "${SSH_DEVICE_KEY:-}"
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_GIT_E2E_SSH_HOST_FINGERPRINT "${SSH_HOST_FINGERPRINT:-}"
  xcodebuild -project "$CLIENT_DIR/Snippets.xcodeproj" -scheme 'Snippets iOS' \
    -configuration Debug -destination "platform=iOS Simulator,id=$IOS_UDID" \
    -derivedDataPath "$IOS_DERIVED" CODE_SIGNING_ALLOWED=NO test-without-building \
    -only-testing:'Snippets iOSTests/GitSyncAppIntegrationTests/testGitSyncPhase' \
    > "$RUN_ROOT/$phase.log" 2>&1 || { tail -40 "$RUN_ROOT/$phase.log" >&2; exit 1; }
  require_passed "$phase"
}

run_mac_phase mac-create
RECOVERY_CODE="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["recoveryCode"])' \
  "$RUN_ROOT/handoff.json")"
[[ "$RECOVERY_CODE" =~ ^[0-9A-Z]{4}(-[0-9A-Z]{1,4}){6}$ ]] || { echo "unexpected recovery code shape" >&2; exit 1; }
run_ios_phase ios-join
run_mac_phase mac-join
run_ios_phase ios-verify

echo "Checking the repository"
check_repository() {
  local bare="$1" expected_records="$2"
  shift 2
  local files records authors history marker
  files="$(git --git-dir "$bare" ls-tree -r --name-only main)"
  grep -qx 'snippets-sync.json' <<<"$files"
  grep -qx 'keys/recovery.json' <<<"$files"
  grep -qx 'keys/vault.json' <<<"$files"
  records="$(grep -c '^records/' <<<"$files" || true)"
  [[ "$records" == "$expected_records" ]] || { echo "expected $expected_records record files, found $records" >&2; exit 1; }
  authors="$(git --git-dir "$bare" log --format='%an <%ae>' main | sort -u)"
  [[ "$authors" == "Snippets Sync <sync@snippets.invalid>" ]] || { echo "unexpected authorship: $authors" >&2; exit 1; }
  history="$(git --git-dir "$bare" log -p main)"
  for marker in "$@"; do
    if grep -qF -- "$marker" <<<"$history"; then
      echo "plaintext found in repository history: $marker" >&2
      exit 1
    fi
  done
  echo "Repository $(basename "$bare"): $records records, $(git --git-dir "$bare" rev-list --count main) commits, ciphertext only"
}
# mac-git, ios-git kept as a tombstone record, and the two secure snippets.
check_repository "$BARE" 4 snippets-git-macos-initial-5c2e91d0 snippets-git-ios-initial-7f03ab64 \
  snippets-git-macos-edited-on-ios-0d6e44a9 "$RECOVERY_CODE" "macOS Git" "iOS Git" \
  snippets-git-macos-secure-b41f07c6 snippets-git-ios-secure-e95a3d28 mac-secure ios-secure

echo "Replacing the keys"
PREVIOUS_CODE="$RECOVERY_CODE"
OLD_DATASET="$(git --git-dir "$BARE" show main:snippets-sync.json | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["datasetID"])')"
run_mac_phase mac-rotate
RECOVERY_CODE="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["recoveryCode"])' \
  "$RUN_ROOT/handoff.json")"
[[ "$RECOVERY_CODE" =~ ^[0-9A-Z]{4}(-[0-9A-Z]{1,4}){6}$ && "$RECOVERY_CODE" != "$PREVIOUS_CODE" ]] \
  || { echo "replacing the keys did not hand over a new recovery code" >&2; exit 1; }
run_ios_phase ios-rotated
PREVIOUS_CODE=""
# One commit replaced the library: a new dataset under schema 2, and only what the
# rotating device holds was uploaded again (mac-git and the two secure snippets; the
# old tombstone is gone with the old library).
git --git-dir "$BARE" show main:snippets-sync.json | python3 -I -c 'import json, sys
manifest = json.load(sys.stdin)
assert manifest["schemaVersion"] == 2, manifest
assert manifest["datasetID"] != sys.argv[1], "the dataset id did not change"' "$OLD_DATASET"
[[ "$(git --git-dir "$BARE" log --format=%s main | grep -c '^Replace library keys$')" == 1 ]] \
  || { echo "expected exactly one key-replacing commit" >&2; exit 1; }
check_repository "$BARE" 3 snippets-git-macos-initial-5c2e91d0 snippets-git-ios-initial-7f03ab64 \
  snippets-git-macos-edited-on-ios-0d6e44a9 "$RECOVERY_CODE" "macOS Git" "iOS Git" \
  snippets-git-macos-secure-b41f07c6 snippets-git-ios-secure-e95a3d28 mac-secure ios-secure

if [[ "${SKIP_PLAIN:-0}" != 1 ]]; then
  echo "Plain-text library"
  PLAIN_BARE="$REPOS/plain.git"
  git init --quiet --bare --initial-branch=main "$PLAIN_BARE"
  URL="http://127.0.0.1:$PORT/plain.git"
  RECOVERY_CODE=""
  run_mac_phase mac-plain-create
  RECOVERY_CODE="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["recoveryCode"])' \
    "$RUN_ROOT/handoff.json")"
  run_ios_phase ios-plain-join
  # A person edits the macOS snippet as an ordinary file and pushes with plain git.
  EDIT_WORK="$RUN_ROOT/plain-edit"
  git clone --quiet "$PLAIN_BARE" "$EDIT_WORK"
  EDIT_FILE="$(grep -l 'snippets-git-macos-initial-5c2e91d0' "$EDIT_WORK"/snippets/*.md)"
  python3 -I -c 'import sys; p = sys.argv[1]; t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("snippets-git-macos-initial-5c2e91d0", "snippets-git-macos-edited-in-git-3a7c19e0"))' \
    "$EDIT_FILE"
  git -C "$EDIT_WORK" -c user.name=Person -c user.email=person@example.invalid -c commit.gpgsign=false \
    commit --quiet -am "Edit a snippet in git"
  git -C "$EDIT_WORK" push --quiet origin HEAD:refs/heads/main
  run_mac_phase mac-plain-verify
  PLAIN_FILES="$(git --git-dir "$PLAIN_BARE" ls-tree -r --name-only main)"
  [[ "$(grep -c '^snippets/.*\.md$' <<<"$PLAIN_FILES")" == 2 ]] || { echo "expected 2 Markdown snippets" >&2; exit 1; }
  # The one ciphertext record is the secure snippet; ordinary snippets are Markdown only.
  [[ "$(grep -c '^records/' <<<"$PLAIN_FILES")" == 1 ]] \
    || { echo "expected exactly the secure snippet under records/" >&2; exit 1; }
  grep -qx 'keys/vault.json' <<<"$PLAIN_FILES" || { echo "the library has no vault file" >&2; exit 1; }
  # Output captured first: with pipefail, `git … | grep -q` can fail on SIGPIPE.
  IOS_PLAIN_TEXT="$(git --git-dir "$PLAIN_BARE" show "main:$(grep '^snippets/ios-plain-' <<<"$PLAIN_FILES")")"
  grep -q 'snippets-git-ios-plain-2d8b5f13' <<<"$IOS_PLAIN_TEXT" \
    || { echo "the iOS snippet is not readable Markdown" >&2; exit 1; }
  PLAIN_SUBJECTS="$(git --git-dir "$PLAIN_BARE" log --format=%s main)"
  grep -q '^Normalize' <<<"$PLAIN_SUBJECTS" \
    || { echo "the hand edit was not normalized; history:" >&2; echo "$PLAIN_SUBJECTS" >&2; exit 1; }
  PLAIN_HISTORY="$(git --git-dir "$PLAIN_BARE" log -p main)"
  ! grep -qF -- "$RECOVERY_CODE" <<<"$PLAIN_HISTORY" || { echo "recovery code in history" >&2; exit 1; }
  for marker in snippets-git-macos-secure-b41f07c6 mac-secure; do
    ! grep -qF -- "$marker" <<<"$PLAIN_HISTORY" || { echo "secure snippet readable in history: $marker" >&2; exit 1; }
  done
  echo "Repository plain.git: readable Markdown, hand edit adopted and normalized"
  URL="http://127.0.0.1:$PORT/library.git"
fi

if [[ "${SKIP_SSH:-0}" != 1 ]]; then
  echo "SSH: throwaway sshd and ssh-agent"
  SSH_DIR="$RUN_ROOT/ssh"
  mkdir -p "$SSH_DIR"
  ssh-keygen -q -t ed25519 -N '' -C host -f "$SSH_DIR/host_key"
  ssh-keygen -q -t ed25519 -N '' -C mac-client -f "$SSH_DIR/mac_key"
  # The iOS device key: P-256, as the app creates. Generated by openssl with a named
  # curve, because CryptoKit refuses the explicit-parameter PEM ssh-keygen writes here.
  openssl ecparam -name prime256v1 -param_enc named_curve -genkey -noout -out "$SSH_DIR/ios_key"
  chmod 600 "$SSH_DIR/ios_key"
  printf '%s ios-device\n' "$(ssh-keygen -y -f "$SSH_DIR/ios_key")" > "$SSH_DIR/ios_key.pub"
  # Logins as this user run nothing but git services on repositories in this run.
  cat > "$SSH_DIR/git-only" <<EOF_GIT_ONLY
#!/bin/sh
# Exactly one git service on one repository named <[A-Za-z0-9_-]+>.git directly in
# $REPOS, run without a shell. Anything else, including "..", is refused.
cmd=\$SSH_ORIGINAL_COMMAND
case "\$cmd" in
  "git-upload-pack '$REPOS/"*".git'") service=git-upload-pack ;;
  "git-receive-pack '$REPOS/"*".git'") service=git-receive-pack ;;
  *) echo "refused" >&2; exit 1 ;;
esac
name=\${cmd#"\$service '$REPOS/"}
name=\${name%".git'"}
case "\$name" in
  ""|*[!A-Za-z0-9_-]*) echo "refused" >&2; exit 1 ;;
esac
exec "/usr/bin/\$service" "$REPOS/\$name.git"
EOF_GIT_ONLY
  chmod 700 "$SSH_DIR/git-only"
  for key in mac_key ios_key; do
    printf 'restrict,command="%s" %s\n' "$SSH_DIR/git-only" "$(cat "$SSH_DIR/$key.pub")"
  done > "$SSH_DIR/authorized_keys"

  # A short socket path (Unix sockets are limited to ~104 bytes) and an explicit
  # SSH_AUTH_SOCK on every use: the user's own agent is never involved.
  AGENT_SOCK="/tmp/snx-$(openssl rand -hex 4).sock"
  /usr/bin/ssh-agent -D -a "$AGENT_SOCK" >/dev/null 2>&1 &
  AGENT_PID=$!
  for _ in $(seq 1 50); do [[ -S "$AGENT_SOCK" ]] && break; sleep 0.1; done
  [[ -S "$AGENT_SOCK" ]] || { echo "private ssh-agent did not start" >&2; exit 1; }
  SSH_AUTH_SOCK="$AGENT_SOCK" ssh-add -q "$SSH_DIR/mac_key"
  [[ "$(SSH_AUTH_SOCK="$AGENT_SOCK" ssh-add -l | wc -l | tr -d ' ')" == 1 ]] || { echo "unexpected agent keys" >&2; exit 1; }
  rm -f -- "$SSH_DIR/mac_key"

  SSH_PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
  cat > "$SSH_DIR/sshd_config" <<EOF_SSHD
Port $SSH_PORT
ListenAddress 127.0.0.1
HostKey $SSH_DIR/host_key
PidFile $SSH_DIR/sshd.pid
AuthorizedKeysFile $SSH_DIR/authorized_keys
AllowUsers $(id -un)
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
LogLevel INFO
EOF_SSHD
  /usr/sbin/sshd -D -e -f "$SSH_DIR/sshd_config" 2> "$SSH_DIR/sshd.log" &
  SSHD_PID=$!
  for _ in $(seq 1 50); do
    python3 -I -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2).close()' \
      "$SSH_PORT" 2>/dev/null && break
    sleep 0.1
  done
  printf '[127.0.0.1]:%s %s\n' "$SSH_PORT" "$(cut -d' ' -f1,2 "$SSH_DIR/host_key.pub")" > "$SSH_DIR/known_hosts"
  SSH_CONFIG="$SSH_DIR/ssh_config"
  cat > "$SSH_CONFIG" <<EOF_CLIENT
Host *
  UserKnownHostsFile $SSH_DIR/known_hosts
  GlobalKnownHostsFile /dev/null
  StrictHostKeyChecking yes
  UpdateHostKeys no
  IdentitiesOnly yes
  IdentityFile $SSH_DIR/mac_key.pub
  IdentityAgent $AGENT_SOCK
EOF_CLIENT
  SSH_HOST_FINGERPRINT="$(ssh-keygen -lf "$SSH_DIR/host_key.pub" -E sha256 | awk '{print $2}')"
  SSH_DEVICE_KEY="$(base64 < "$SSH_DIR/ios_key" | tr -d '\n')"

  SSH_BARE="$REPOS/ssh.git"
  git init --quiet --bare --initial-branch=main "$SSH_BARE"
  URL="ssh://$(id -un)@127.0.0.1:$SSH_PORT$SSH_BARE"
  RECOVERY_CODE=""
  run_mac_phase mac-ssh-create
  RECOVERY_CODE="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["recoveryCode"])' \
    "$RUN_ROOT/handoff.json")"
  run_ios_phase ios-ssh-join
  # Every exchange of that phase shared one authenticated connection.
  IOS_KEY_FINGERPRINT="$(ssh-keygen -lf "$SSH_DIR/ios_key.pub" -E sha256 | awk '{print $2}')"
  IOS_LOGINS="$(grep -c "Accepted publickey.*$IOS_KEY_FINGERPRINT" "$SSH_DIR/sshd.log" || true)"
  [[ "$IOS_LOGINS" == 1 ]] || { echo "iOS opened $IOS_LOGINS SSH connections; expected one shared" >&2; exit 1; }
  echo "  ios-ssh-join used one shared SSH connection"
  run_mac_phase mac-ssh-verify
  check_repository "$SSH_BARE" 2 snippets-git-macos-initial-5c2e91d0 snippets-git-ios-over-ssh-91b7e2c4 \
    "$RECOVERY_CODE" "macOS Git" "iOS SSH"
  kill "$SSHD_PID" "$AGENT_PID" >/dev/null 2>&1 || true
  SSHD_PID=""; AGENT_PID=""
  rm -f -- "$AGENT_SOCK"; AGENT_SOCK=""; SSH_CONFIG=""; SSH_DEVICE_KEY=""; SSH_HOST_FINGERPRINT=""
  URL="http://127.0.0.1:$PORT/library.git"
fi

if [[ "${SKIP_UI:-0}" != 1 ]]; then
  # The iOS Settings UI connects an empty repository, creates the library, switches
  # sync, replaces the library's keys and copies the new recovery code; a fresh macOS
  # installation then joins with it.
  # `--ui-testing-reset` keeps the provider choice in a disposable defaults suite and
  # sync on/off in process, so the Debug app's own preferences are never changed.
  UI_BARE="$REPOS/ui.git"
  git init --quiet --bare --initial-branch=main "$UI_BARE"
  URL="http://127.0.0.1:$PORT/ui.git"
  echo "iOS UI: Settings → Git Repository"
  xcrun simctl pbcopy "$IOS_UDID" <<<"" >/dev/null 2>&1 || true
  TEST_RUNNER_SNIPPETS_GIT_UI_E2E_URL="$URL" \
  TEST_RUNNER_SNIPPETS_GIT_UI_E2E_USERNAME="$USERNAME" \
  TEST_RUNNER_SNIPPETS_GIT_UI_E2E_TOKEN="$TOKEN" \
  xcodebuild -project "$CLIENT_DIR/Snippets.xcodeproj" -scheme 'Snippets iOS' \
    -configuration Debug -destination "platform=iOS Simulator,id=$IOS_UDID" \
    -derivedDataPath "$IOS_DERIVED" CODE_SIGNING_ALLOWED=NO test-without-building \
    -only-testing:'Snippets iOSUITests/GitSyncSettingsUITests' \
    > "$RUN_ROOT/ios-ui.log" 2>&1 || { tail -60 "$RUN_ROOT/ios-ui.log" >&2; exit 1; }
  if grep -q "GitSyncSettingsUITests.*skipped" "$RUN_ROOT/ios-ui.log" \
      || ! grep -q "GitSyncSettingsUITests.*passed" "$RUN_ROOT/ios-ui.log"; then
    echo "the iOS Git settings UI test did not pass" >&2
    grep -E "GitSyncSettingsUITests|error|XCTAssert" "$RUN_ROOT/ios-ui.log" | tail -20 >&2
    exit 1
  fi
  echo "  ios-ui passed"
  RECOVERY_CODE="$(xcrun simctl pbpaste "$IOS_UDID" | tr -d '[:space:]')"
  [[ "$RECOVERY_CODE" =~ ^[0-9A-Z]{4}(-[0-9A-Z]{1,4}){6}$ ]] || { echo "the UI did not copy a recovery code" >&2; exit 1; }
  xcrun simctl pbcopy "$IOS_UDID" <<<"" >/dev/null 2>&1 || true
  # The UI replaced the library's keys after creating it; the code it copied last is
  # the new library's, which the macOS join below then proves.
  git --git-dir "$UI_BARE" show main:snippets-sync.json | python3 -I -c 'import json, sys
assert json.load(sys.stdin)["schemaVersion"] == 2, "the UI did not replace the keys"'
  [[ "$(git --git-dir "$UI_BARE" log --format=%s main | grep -c '^Replace library keys$')" == 1 ]] \
    || { echo "expected exactly one key-replacing commit from the UI" >&2; exit 1; }
  run_mac_phase mac-verify-ui
  check_repository "$UI_BARE" 1 "Hello from the Git settings UI 4c9e" "Git UI Greeting" "$RECOVERY_CODE"
fi
echo "Git sync integration test passed"
