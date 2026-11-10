#!/usr/bin/env bash
# Git sync end to end against a real GitHub repository, through the app code on macOS
# and an iOS simulator. Opt-in; it writes to the repository you name.
#
#   scripts/test-git-sync-hosted.sh owner/scratch-repo
#   SKIP_BUILD=1 SNIPPETS_GIT_E2E_IOS_UDID=<udid> scripts/test-git-sync-hosted.sh owner/scratch-repo
#
# Requirements: a scratch repository you own, `gh` signed in with `repo` scope, and an
# SSH key in your agent that GitHub accepts (check: ssh -T git@github.com).
#
# Each stage uses a new branch, so earlier runs are never touched:
#   HTTPS (token from `gh auth token`): mac-create → ios-join → mac-join → ios-verify
#   SSH: mac-ssh-create with your own ssh, agent and ~/.ssh/config, exactly as the Mac
#   app runs it → ios-ssh-join with a fresh iOS device key, added as a write deploy key
#   for the run only, confirming GitHub's host key against your known_hosts → mac-ssh-verify.
# Afterwards each branch is fetched and checked: record count, fixed authorship, and no
# plaintext marker or recovery code anywhere in its history. The token is passed only
# through the environment and never printed; the deploy key is removed at exit.
set -euo pipefail
umask 077

REPO="${1:?usage: $0 owner/repository}"
CLIENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAC_CONFIG="/tmp/snippets-git-sync-e2e-macos.json"
MAC_DERIVED="${SNIPPETS_MACOS_DERIVED:-/tmp/snippets-macos-derived}"
IOS_DERIVED="${SNIPPETS_IOS_DERIVED:-/tmp/snippets-ios-derived}"
IOS_UDID="${SNIPPETS_GIT_E2E_IOS_UDID:-}"
IOS_BOOTED_HERE=0
MAC_CONFIG_OWNED=0
DEPLOY_KEY_ID=""
RUN_ID="$(openssl rand -hex 4)"

for executable in gh git ssh ssh-keygen openssl python3 xcodebuild xcrun; do
  command -v "$executable" >/dev/null || { echo "missing executable: $executable" >&2; exit 1; }
done
[[ ! -e "$MAC_CONFIG" ]] || { echo "refusing to overwrite $MAC_CONFIG" >&2; exit 1; }
gh repo view "$REPO" --json name >/dev/null
# `ssh -T` to GitHub always exits 1 (no shell access); judge it by its greeting.
SSH_GREETING="$(ssh -o BatchMode=yes -T git@github.com 2>&1 || true)"
grep -q "successfully authenticated" <<<"$SSH_GREETING" \
  || { echo "ssh -T git@github.com does not authenticate with your agent" >&2; exit 1; }

RUN_ROOT="$(mktemp -d /tmp/snippets-git-hosted.XXXXXX)"
cleanup() {
  set +e
  [[ "$MAC_CONFIG_OWNED" == 1 ]] && rm -f -- "$MAC_CONFIG"
  [[ -z "$DEPLOY_KEY_ID" ]] || gh repo deploy-key delete "$DEPLOY_KEY_ID" --repo "$REPO" >/dev/null 2>&1
  if [[ -n "$IOS_UDID" ]]; then
    for name in SNIPPETS_GIT_E2E SNIPPETS_GIT_E2E_URL SNIPPETS_GIT_E2E_USERNAME SNIPPETS_GIT_E2E_TOKEN \
      SNIPPETS_GIT_E2E_PHASE SNIPPETS_GIT_E2E_RECOVERY_CODE SNIPPETS_GIT_E2E_BRANCH \
      SNIPPETS_GIT_E2E_SSH_DEVICE_KEY SNIPPETS_GIT_E2E_SSH_HOST_FINGERPRINT; do
      xcrun simctl spawn "$IOS_UDID" launchctl unsetenv "$name" >/dev/null 2>&1
    done
    [[ "$IOS_BOOTED_HERE" == 1 ]] && xcrun simctl shutdown "$IOS_UDID" >/dev/null 2>&1
  fi
  [[ "$RUN_ROOT" == /tmp/snippets-git-hosted.* ]] && rm -rf -- "$RUN_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -z "$IOS_UDID" ]]; then
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

if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
  echo "Building"
  xcodebuild -quiet -project "$CLIENT_DIR/Snippets.xcodeproj" -scheme Snippets -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$MAC_DERIVED" CODE_SIGNING_ALLOWED=NO build-for-testing
  xcodebuild -quiet -project "$CLIENT_DIR/Snippets.xcodeproj" -scheme 'Snippets iOS' -configuration Debug \
    -destination "platform=iOS Simulator,id=$IOS_UDID" -derivedDataPath "$IOS_DERIVED" CODE_SIGNING_ALLOWED=NO build-for-testing
fi

TOKEN="$(gh auth token)"
USERNAME="x-access-token"
URL=""
BRANCH=""
RECOVERY_CODE=""
SSH_AGENT_FOR_MAC=""
SSH_DEVICE_KEY=""
SSH_HOST_FINGERPRINT=""

require_passed() {
  local phase="$1"
  if grep -q "testGitSyncPhase.*skipped" "$RUN_ROOT/$phase.log" \
      || ! grep -q "testGitSyncPhase.*passed" "$RUN_ROOT/$phase.log"; then
    echo "phase $phase did not run to a pass" >&2
    grep -E "testGitSyncPhase|error:|XCTAssert|skipped" "$RUN_ROOT/$phase.log" | tail -20 >&2
    exit 1
  fi
}

run_mac_phase() {
  local phase="$1" started=$SECONDS
  python3 -I -c 'import json, sys; a = sys.argv; json.dump({"repositoryURL": a[1], "username": a[2],
    "token": a[3], "phase": a[4], "recoveryCode": a[5] or None, "handoffPath": a[6], "branch": a[8],
    "sshAgentSocket": a[9] or None}, open(a[7], "w"))' \
    "$URL" "$USERNAME" "$TOKEN" "$phase" "$RECOVERY_CODE" "$RUN_ROOT/handoff.json" "$MAC_CONFIG" \
    "$BRANCH" "$SSH_AGENT_FOR_MAC"
  MAC_CONFIG_OWNED=1
  xcodebuild -project "$CLIENT_DIR/Snippets.xcodeproj" -scheme Snippets -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$MAC_DERIVED" CODE_SIGNING_ALLOWED=NO \
    test-without-building -only-testing:'Snippets macOSTests/GitSyncAppIntegrationTests/testGitSyncPhase' \
    > "$RUN_ROOT/$phase.log" 2>&1 || { tail -40 "$RUN_ROOT/$phase.log" >&2; exit 1; }
  rm -f -- "$MAC_CONFIG"
  require_passed "$phase"
  echo "  $phase passed ($((SECONDS - started)) s including test launch)"
}

run_ios_phase() {
  local phase="$1" started=$SECONDS name value
  for pair in "SNIPPETS_GIT_E2E=1" "SNIPPETS_GIT_E2E_URL=$URL" "SNIPPETS_GIT_E2E_USERNAME=$USERNAME" \
      "SNIPPETS_GIT_E2E_PHASE=$phase" "SNIPPETS_GIT_E2E_RECOVERY_CODE=$RECOVERY_CODE" \
      "SNIPPETS_GIT_E2E_BRANCH=$BRANCH" "SNIPPETS_GIT_E2E_SSH_DEVICE_KEY=$SSH_DEVICE_KEY" \
      "SNIPPETS_GIT_E2E_SSH_HOST_FINGERPRINT=$SSH_HOST_FINGERPRINT"; do
    name="${pair%%=*}"; value="${pair#*=}"
    xcrun simctl spawn "$IOS_UDID" launchctl setenv "$name" "$value"
  done
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_GIT_E2E_TOKEN "$TOKEN"
  xcodebuild -project "$CLIENT_DIR/Snippets.xcodeproj" -scheme 'Snippets iOS' -configuration Debug \
    -destination "platform=iOS Simulator,id=$IOS_UDID" -derivedDataPath "$IOS_DERIVED" CODE_SIGNING_ALLOWED=NO \
    test-without-building -only-testing:'Snippets iOSTests/GitSyncAppIntegrationTests/testGitSyncPhase' \
    > "$RUN_ROOT/$phase.log" 2>&1 || { tail -40 "$RUN_ROOT/$phase.log" >&2; exit 1; }
  xcrun simctl spawn "$IOS_UDID" launchctl unsetenv SNIPPETS_GIT_E2E_TOKEN
  require_passed "$phase"
  echo "  $phase passed ($((SECONDS - started)) s including test launch)"
}

read_recovery_code() {
  RECOVERY_CODE="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["recoveryCode"])' \
    "$RUN_ROOT/handoff.json")"
  [[ "$RECOVERY_CODE" =~ ^[0-9A-Z]{4}(-[0-9A-Z]{1,4}){6}$ ]] || { echo "unexpected recovery code shape" >&2; exit 1; }
}

check_branch() {
  local branch="$1" expected_records="$2"
  shift 2
  local bare="$RUN_ROOT/check-$branch.git" files records authors history marker
  git init --quiet --bare "$bare"
  git -C "$bare" fetch --quiet "git@github.com:$REPO.git" "refs/heads/${branch}:refs/heads/${branch}"
  files="$(git --git-dir "$bare" ls-tree -r --name-only "$branch")"
  grep -qx 'snippets-sync.json' <<<"$files"
  grep -qx 'keys/recovery.json' <<<"$files"
  records="$(grep -c '^records/' <<<"$files" || true)"
  [[ "$records" == "$expected_records" ]] || { echo "expected $expected_records record files, found $records" >&2; exit 1; }
  authors="$(git --git-dir "$bare" log --format='%an <%ae>' "$branch" | sort -u)"
  [[ "$authors" == "Snippets Sync <sync@snippets.invalid>" ]] || { echo "unexpected authorship: $authors" >&2; exit 1; }
  history="$(git --git-dir "$bare" log -p "$branch")"
  for marker in "$@"; do
    if grep -qF -- "$marker" <<<"$history"; then echo "plaintext in history: $marker" >&2; exit 1; fi
  done
  echo "  $branch: $records records, $(git --git-dir "$bare" rev-list --count "$branch") commits, ciphertext only"
}

echo "HTTPS stage"
URL="https://github.com/$REPO"
BRANCH="e2e-https-$RUN_ID"
run_mac_phase mac-create
read_recovery_code
run_ios_phase ios-join
run_mac_phase mac-join
run_ios_phase ios-verify
check_branch "$BRANCH" 2 snippets-git-macos-initial-5c2e91d0 snippets-git-ios-initial-7f03ab64 \
  snippets-git-macos-edited-on-ios-0d6e44a9 "$RECOVERY_CODE" "macOS Git" "iOS Git"

echo "Plain-text stage"
URL="https://github.com/$REPO"
BRANCH="e2e-plain-$RUN_ID"
RECOVERY_CODE=""
run_mac_phase mac-plain-create
read_recovery_code
run_ios_phase ios-plain-join
# Edit the macOS snippet as an ordinary file and push with plain git, as a person would.
git clone --quiet --branch "$BRANCH" "git@github.com:$REPO.git" "$RUN_ROOT/plain-edit"
EDIT_FILE="$(grep -l 'snippets-git-macos-initial-5c2e91d0' "$RUN_ROOT"/plain-edit/snippets/*.md)"
python3 -I -c 'import sys; p = sys.argv[1]; t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("snippets-git-macos-initial-5c2e91d0", "snippets-git-macos-edited-in-git-3a7c19e0"))' "$EDIT_FILE"
git -C "$RUN_ROOT/plain-edit" -c user.name="Snippets test" -c user.email=test@example.invalid -c commit.gpgsign=false \
  commit --quiet -am "Edit a snippet in git"
git -C "$RUN_ROOT/plain-edit" push --quiet origin "HEAD:refs/heads/$BRANCH"
run_mac_phase mac-plain-verify
PLAIN_SUBJECTS="$(git -C "$RUN_ROOT/plain-edit" fetch --quiet origin "$BRANCH" && git -C "$RUN_ROOT/plain-edit" log --format=%s FETCH_HEAD)"
grep -q '^Normalize' <<<"$PLAIN_SUBJECTS" || { echo "the hand edit was not normalized" >&2; exit 1; }
echo "  $BRANCH: readable Markdown on GitHub, hand edit adopted and normalized"

echo "SSH stage"
# The iOS device key for this run only, as a write deploy key.
openssl ecparam -name prime256v1 -param_enc named_curve -genkey -noout -out "$RUN_ROOT/ios_key"
printf '%s snippets-e2e-%s\n' "$(ssh-keygen -y -f "$RUN_ROOT/ios_key")" "$RUN_ID" > "$RUN_ROOT/ios_key.pub"
gh repo deploy-key add "$RUN_ROOT/ios_key.pub" --repo "$REPO" --allow-write --title "snippets-e2e-ios-$RUN_ID" >/dev/null
DEPLOY_KEY_ID="$(gh repo deploy-key list --repo "$REPO" --json id,title \
  --jq ".[] | select(.title == \"snippets-e2e-ios-$RUN_ID\") | .id")"
[[ -n "$DEPLOY_KEY_ID" ]] || { echo "deploy key was not added" >&2; exit 1; }
SSH_DEVICE_KEY="$(base64 < "$RUN_ROOT/ios_key" | tr -d '\n')"
# What the user would compare against: the github.com keys already in known_hosts.
SSH_HOST_FINGERPRINT="$(ssh-keygen -F github.com | grep -v '^#' | ssh-keygen -lf - -E sha256 \
  | awk '{print $2}' | sort -u | paste -sd, -)"
[[ -n "$SSH_HOST_FINGERPRINT" ]] || { echo "github.com is not in known_hosts" >&2; exit 1; }
SSH_AGENT_FOR_MAC="${SSH_AUTH_SOCK:-}"
URL="git@github.com:$REPO.git"
BRANCH="e2e-ssh-$RUN_ID"
RECOVERY_CODE=""
run_mac_phase mac-ssh-create
read_recovery_code
run_ios_phase ios-ssh-join
run_mac_phase mac-ssh-verify
check_branch "$BRANCH" 2 snippets-git-macos-initial-5c2e91d0 snippets-git-ios-over-ssh-91b7e2c4 \
  "$RECOVERY_CODE" "macOS Git" "iOS SSH"
echo "Hosted Git sync test passed against $REPO"
