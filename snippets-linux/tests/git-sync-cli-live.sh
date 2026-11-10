#!/usr/bin/env bash
# Two isolated installations exchange a library through `snippets-cli git`,
# with a private bus/keyring and a loopback `git http-backend`. No desktop,
# login keyring, user library, ssh agent or git configuration is involved.
#   tests/git-sync-cli-live.sh /path/to/snippets-cli
set -euo pipefail
umask 077
if [[ ${1:-} == --in-bus ]]; then
  cli=$2
  root=$3
  if [[ $DBUS_SESSION_BUS_ADDRESS == ${SNIPPETS_SECRET_HOST_BUS:-} ]]; then
    printf '%s\n' 'Refusing to test on the desktop bus.' >&2
    exit 1
  fi
  unset SNIPPETS_SUPPORT_DIR SSH_AUTH_SOCK SSH_AGENT_PID
  # The fixture daemon stores its keyrings under XDG_DATA_HOME. Without this
  # it would fall back to the user's ~/.local/share/keyrings.
  export XDG_DATA_HOME=$root/keyring-data
  mkdir -m 700 "$XDG_DATA_HOME"
  if [[ $XDG_DATA_HOME != /tmp/snippets-git-cli.*/keyring-data || ! -d $XDG_DATA_HOME ]]; then
    printf '%s\n' 'Refusing to start a keyring outside the fixture.' >&2
    exit 1
  fi
  printf '%s' 'Public fictional keyring fixture password' |
    gnome-keyring-daemon --foreground --components=secrets --unlock \
      --control-directory="$root/control" >"$root/daemon.log" 2>&1 &
  daemon=$!
  trap 'kill "$daemon" 2>/dev/null || true; wait "$daemon" 2>/dev/null || true' EXIT
  for _ in $(seq 1 50); do
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.NameHasOwner org.freedesktop.secrets 2>/dev/null | grep -q true && break
    sleep 0.1
  done
  [[ -f $XDG_DATA_HOME/keyrings/login.keyring ]] || { printf '%s\n' 'The fixture keyring is not in the fixture.' >&2; exit 1; }
  token=$(cat "$root/token")
  a() { XDG_DATA_HOME=$root/a "$cli" "$@"; }
  b() { XDG_DATA_HOME=$root/b "$cli" "$@"; }
  field() { python3 -I -c 'import json,sys; v=json.load(sys.stdin); print(v.get(sys.argv[1]) if isinstance(v, dict) else "")' "$1"; }
  expect() { [[ $1 == "$2" ]] || { printf 'expected %s, got %s (%s)\n' "$2" "$1" "$3" >&2; exit 1; }; }
  sync_state() { "$@" git sync | field state; }
  target=(--repository "$URL" --username tester)

  a add --name 'Linux CLI' --keyword linux-cli --content 'linux-cli-initial-71c2' >/dev/null
  expect "$(a git status | field connected)" False status
  if printf '%s\n' wrong-token | a git inspect "${target[@]}" --token-stdin >/dev/null 2>"$root/err"; then exit 1; fi
  grep -q '(git_authentication)' "$root/err"
  expect "$(printf '%s\n' "$token" | a git inspect "${target[@]}" --token-stdin | field state)" empty inspect
  code=$(printf '%s\n' "$token" | a git create "${target[@]}" --token-stdin | field recoveryCode)
  [[ ${#code} == 33 ]]
  expect "$(sync_state a)" current a-sync
  expect "$(a git status | field transport)" https transport

  # B: a wrong code is refused, the right one joins.
  expect "$(printf '%s\n' "$token" | b git inspect "${target[@]}" --token-stdin | field recoveryAvailable)" True recovery
  if printf '%s\n%s\n' "$token" 0000-0000-0000-0000-0000-0000-000 |
      b git join "${target[@]}" --token-stdin --recovery-code-stdin >/dev/null 2>"$root/err"; then exit 1; fi
  grep -q '(incorrect_recovery_code)' "$root/err"
  printf '%s\n%s\n' "$token" "$code" | b git join "${target[@]}" --token-stdin --recovery-code-stdin >/dev/null
  expect "$(sync_state b)" current b-sync
  b get linux-cli | grep -q 'linux-cli-initial-71c2'
  b add --name 'Second' --keyword second --content 'second-from-b-0f3a' >/dev/null
  expect "$(sync_state b)" current b-sync-2
  expect "$(sync_state a)" current a-sync-2
  a get second | grep -q 'second-from-b-0f3a'

  # Deletion on A is reviewed on both installations.
  a delete second >/dev/null
  expect "$(sync_state a)" deletion_review a-review
  expect "$(a git deletion-review | field kind)" local_absence a-kind
  a git deletion-review --delete >/dev/null
  expect "$(sync_state a)" current a-sync-3
  expect "$(sync_state b)" deletion_review b-review
  expect "$(b git deletion-review | field kind)" remote_deletion b-kind
  b git deletion-review --delete >/dev/null
  expect "$(sync_state b)" current b-sync-3
  if b get second >/dev/null 2>&1; then exit 1; fi

  # A plain-text library: ordinary snippets are Markdown in the repository,
  # joining needs consent, and an edit made with plain git is adopted once.
  plain=(--repository "${URL%library.git}plain.git" --username tester)
  repo=$root/http/plain.git
  c() { XDG_DATA_HOME=$root/c "$cli" "$@"; }
  d() { XDG_DATA_HOME=$root/d "$cli" "$@"; }
  hand() { GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -c user.name=Hand -c user.email=hand@example.invalid "$@"; }
  c add --name 'Plain CLI' --keyword plain-cli --content 'plain-cli-body-6e0b' >/dev/null
  plain_code=$(printf '%s\n' "$token" | c git create "${plain[@]}" --token-stdin --plain-text | field recoveryCode)
  [[ ${#plain_code} == 33 ]]
  expect "$(c git status | field mode)" plain_text c-mode
  expect "$(c git status | field modeDescription)" 'Ordinary snippets are saved as readable Markdown files in your Git repository. Secure snippets stay encrypted.' c-mode-line
  expect "$(sync_state c)" current c-sync
  file=$(hand --git-dir "$repo" ls-tree -r --name-only main snippets/)
  [[ $file == snippets/plain-cli-*.md ]] || { printf 'unexpected file %s\n' "$file" >&2; exit 1; }
  hand --git-dir "$repo" show "main:$file" | grep -qx 'plain-cli-body-6e0b'
  hand --git-dir "$repo" show main:snippets-sync.json | grep -q '"snippets-plain-v1"'
  expect "$(printf '%s\n' "$token" | d git inspect "${plain[@]}" --token-stdin | field mode)" plain_text d-inspect
  if printf '%s\n%s\n' "$token" "$plain_code" |
      d git join "${plain[@]}" --token-stdin --recovery-code-stdin >/dev/null 2>"$root/err"; then exit 1; fi
  grep -q '(plain_text_consent_required)' "$root/err"
  expect "$(d git status | field connected)" False d-not-connected
  printf '%s\n%s\n' "$token" "$plain_code" |
    d git join "${plain[@]}" --token-stdin --recovery-code-stdin --accept-plain-text >/dev/null
  expect "$(sync_state d)" current d-sync
  d get plain-cli | grep -q 'plain-cli-body-6e0b'
  hand clone --quiet "$repo" "$root/plain-work"
  sed -i 's/plain-cli-body-6e0b/plain-cli-edited-in-git-2c4d/' "$root/plain-work/$file"
  hand -C "$root/plain-work" commit --quiet -am 'Edit by hand'
  hand -C "$root/plain-work" push --quiet origin main
  expect "$(sync_state c)" current c-sync-2
  expect "$(sync_state d)" current d-sync-2
  c get plain-cli | grep -q 'plain-cli-edited-in-git-2c4d'
  d get plain-cli | grep -q 'plain-cli-edited-in-git-2c4d'
  expect "$(hand --git-dir "$repo" log --format=%s main | grep -c '^Normalize')" 1 normalized-once
  commits=$(hand --git-dir "$repo" rev-list --count main)
  expect "$(sync_state c)" current c-sync-3
  expect "$(sync_state d)" current d-sync-3
  expect "$(hand --git-dir "$repo" rev-list --count main)" "$commits" no-back-and-forth
  # An edit made on Linux is written back as Markdown at the same path.
  d update plain-cli --content 'plain-cli-from-d-71aa' >/dev/null
  expect "$(sync_state d)" current d-sync-4
  hand --git-dir "$repo" show "main:$file" | grep -qx 'plain-cli-from-d-71aa'
  expect "$(sync_state c)" current c-sync-4
  c get plain-cli | grep -q 'plain-cli-from-d-71aa'

  # A branch that already has files (a README): the CLI points to a branch
  # of its own, which is empty and can hold the library.
  e() { XDG_DATA_HOME=$root/e "$cli" "$@"; }
  foreign=(--repository "${URL%library.git}foreign.git" --username tester)
  printf '%s\n' "$token" | e git inspect "${foreign[@]}" --token-stdin >"$root/out"
  expect "$(field state <"$root/out")" foreign foreign-inspect
  grep -qF -- '--branch snippets' "$root/out"
  if printf '%s\n' "$token" | e git create "${foreign[@]}" --token-stdin >/dev/null 2>"$root/err"; then exit 1; fi
  grep -qxF 'hint: Try again with --branch snippets.' "$root/err"
  expect "$(printf '%s\n' "$token" | e git inspect "${foreign[@]}" --branch snippets --token-stdin | field state)" empty own-branch

  # The token and codes live only in the private keyring, never in files.
  for needle in "$token" "$code" "$plain_code"; do
    if grep -rqF -- "$needle" "$root/a" "$root/b" "$root/c" "$root/d" "$root/e" "$root/http"; then
      printf '%s\n' 'a secret reached a file' >&2
      exit 1
    fi
  done
  b git disconnect >/dev/null
  expect "$(b git status | field connected)" False disconnected
  # Reconnecting needs the token again but no recovery code: the key stayed.
  printf '%s\n' "$token" | b git join "${target[@]}" --token-stdin >/dev/null
  expect "$(sync_state b)" current b-sync-4
  printf '%s\n' 'git sync cli acceptance: ok'
  exit
fi
if [[ $# != 1 || ! -x $1 ]]; then
  printf '%s\n' 'Usage: git-sync-cli-live.sh /path/to/snippets-cli' >&2
  exit 2
fi
# The real keyring directory, resolved before anything overrides XDG_DATA_HOME.
real_keyrings=${XDG_DATA_HOME:-$HOME/.local/share}/keyrings
here=$(cd "$(dirname "$0")" && pwd)
server_script=${SNIPPETS_GIT_HTTP_SERVER:-$here/../../scripts/git-http-test-server.py}
root=$(mktemp -d /tmp/snippets-git-cli.XXXXXXXX)
runtime=$(mktemp -d /tmp/sc.XXXXXX)
server_pid=''
cleanup() {
  [[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  [[ $root == /tmp/snippets-git-cli.* ]] && rm -rf -- "$root"
  [[ $runtime == /tmp/sc.* ]] && rm -rf -- "$runtime"
}
trap cleanup EXIT
mkdir -m 700 "$root/a" "$root/b" "$root/c" "$root/d" "$root/e" "$root/control" "$root/http"
fixture_git() { GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -c user.name=Hand -c user.email=hand@example.invalid "$@"; }
fixture_git init --quiet --bare --initial-branch=main "$root/http/library.git"
fixture_git init --quiet --bare --initial-branch=main "$root/http/plain.git"
# A repository whose branch already has a README.
fixture_git init --quiet --bare --initial-branch=main "$root/http/foreign.git"
fixture_git init --quiet --initial-branch=main "$root/readme-work"
printf '%s\n' '# Notes' >"$root/readme-work/README.md"
fixture_git -C "$root/readme-work" add README.md
fixture_git -C "$root/readme-work" commit --quiet -m 'Add README'
fixture_git -C "$root/readme-work" push --quiet "$root/http/foreign.git" main
python3 -I -c 'import secrets; print(secrets.token_hex(20))' >"$root/token"
python3 -I "$server_script" --root "$root/http" --username tester --token-file "$root/token" \
  >"$root/http.out" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do grep -q '^READY ' "$root/http.out" 2>/dev/null && break; sleep 0.1; done
port=$(awk '/^READY /{print $2}' "$root/http.out")
[[ -n $port ]] || { printf '%s\n' 'git test server did not start' >&2; exit 1; }
cat >"$root/bus.conf" <<XML
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=$runtime</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="$UID"/>
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
XML
export URL="http://127.0.0.1:$port/library.git"
export SNIPPETS_GIT_ALLOW_INSECURE_LOOPBACK=1
export XDG_RUNTIME_DIR=$runtime
export SNIPPETS_SECRET_HOST_BUS=${DBUS_SESSION_BUS_ADDRESS:-}
login_keyrings() { find "$real_keyrings" -maxdepth 1 -printf '%f %s %T@\n' 2>/dev/null | sort; }
before=$(login_keyrings)
# Capture the result first: the keyring comparison runs even after a failure.
status=0
dbus-run-session --config-file="$root/bus.conf" -- bash "$0" --in-bus "$1" "$root" || status=$?
after=$(login_keyrings)
if [[ $before != "$after" ]]; then
  printf '%s\n' 'The login keyring directory changed during the fixture run.' >&2
  exit 1
fi
exit "$status"
