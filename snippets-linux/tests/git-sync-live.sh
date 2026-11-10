#!/usr/bin/env bash
# Live Git sync transports against disposable loopback fixtures only:
#   1. HTTP Basic token auth through the real `git http-backend`
#      (scripts/git-http-test-server.py), bound to 127.0.0.1.
#   2. The system ssh against a private, unprivileged sshd on 127.0.0.1 with a
#      throwaway host key, a throwaway client key in a private ssh-agent, and a
#      private ssh config/known_hosts passed with -F. The user's agent, keys,
#      ~/.ssh/config and known_hosts are never read or written.
#
#   tests/git-sync-live.sh /path/to/compiled/library-test-binary
set -euo pipefail
umask 077
if [[ $# != 1 || ! -x $1 ]]; then
  printf '%s\n' 'Usage: git-sync-live.sh /path/to/compiled/library-test-binary' >&2
  exit 2
fi
test_binary=$1
# The real keyring directory; this harness never starts a keyring, and fails
# if that directory changes anyway.
real_keyrings=${XDG_DATA_HOME:-$HOME/.local/share}/keyrings
login_keyrings() { find "$real_keyrings" -maxdepth 1 -printf '%f %s %T@\n' 2>/dev/null | sort; }
keyrings_before=$(login_keyrings)
here=$(cd "$(dirname "$0")" && pwd)
server_script=${SNIPPETS_GIT_HTTP_SERVER:-$here/../../scripts/git-http-test-server.py}
for tool in git python3 ssh sshd ssh-agent ssh-add ssh-keygen; do
  command -v "$tool" >/dev/null || { printf 'missing executable: %s\n' "$tool" >&2; exit 2; }
done
[[ -f $server_script ]] || { printf '%s\n' 'git-http-test-server.py not found' >&2; exit 2; }

# Short root: Unix socket paths are limited to ~104 bytes.
root=$(mktemp -d /tmp/sgs.XXXXXX)
server_pid='' sshd_pid='' agent_pid=''
cleanup() {
  set +e
  [[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null
  [[ -n $sshd_pid ]] && kill "$sshd_pid" 2>/dev/null
  [[ -n $agent_pid ]] && kill "$agent_pid" 2>/dev/null
  wait 2>/dev/null
  [[ $root == /tmp/sgs.* ]] && rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Never inherit the user's agent, even transiently.
unset SSH_AUTH_SOCK SSH_AGENT_PID

# 1. HTTP fixture.
mkdir -p "$root/http"
git init --quiet --bare --initial-branch=main "$root/http/library.git"
openssl rand -hex 20 >"$root/token" 2>/dev/null || python3 -I -c 'import secrets; print(secrets.token_hex(20))' >"$root/token"
python3 -I "$server_script" --root "$root/http" --username tester \
  --token-file "$root/token" >"$root/http.out" 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do
  grep -q '^READY ' "$root/http.out" 2>/dev/null && break
  sleep 0.1
done
port=$(awk '/^READY /{print $2}' "$root/http.out")
[[ -n $port ]] || { printf '%s\n' 'git test server did not start' >&2; exit 1; }

# 2. SSH fixture: private sshd, private agent on a short socket path.
mkdir -p "$root/ssh" "$root/repos" "$root/ssh-home"
git init --quiet --bare --initial-branch=main "$root/repos/library.git"
git init --quiet --bare --initial-branch=main "$root/repos/plain.git"
ssh-keygen -q -t ed25519 -N '' -C snippets-fixture-host -f "$root/ssh/host" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C snippets-fixture-client -f "$root/ssh/client" >/dev/null
printf 'restrict %s\n' "$(cat "$root/ssh/client.pub")" >"$root/ssh/authorized_keys"
ssh_port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
user=$(id -un)
cat >"$root/ssh/sshd_config" <<EOF
Port $ssh_port
ListenAddress 127.0.0.1
HostKey $root/ssh/host
PidFile $root/ssh/sshd.pid
AuthorizedKeysFile $root/ssh/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers $user
PermitRootLogin no
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTTY no
LogLevel ERROR
# The remote git runs with a fixture HOME and no user or system git config.
SetEnv HOME=$root/ssh-home GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
EOF
"$(command -v sshd)" -D -e -f "$root/ssh/sshd_config" 2>"$root/ssh/sshd.log" &
sshd_pid=$!
agent_socket=$root/a
ssh-agent -D -a "$agent_socket" >/dev/null 2>&1 &
agent_pid=$!
for _ in $(seq 1 50); do [[ -S $agent_socket ]] && break; sleep 0.1; done
if [[ ! -S $agent_socket ]]; then
  printf '%s\n' 'The private ssh-agent did not start; refusing to continue.' >&2
  exit 1
fi
export SSH_AUTH_SOCK=$agent_socket
ssh-add -q "$root/ssh/client" 2>/dev/null
[[ $(ssh-add -l | wc -l) == 1 ]] || { printf '%s\n' 'unexpected private agent contents' >&2; exit 1; }
rm -f "$root/ssh/client"  # only the agent holds the private key now
printf '[127.0.0.1]:%s %s\n' "$ssh_port" "$(cut -d' ' -f1-2 "$root/ssh/host.pub")" >"$root/ssh/known_hosts"
: >"$root/ssh/empty_known_hosts"
write_config() {
  cat >"$1" <<EOF
Host snippets-fixture
  HostName 127.0.0.1
  Port $ssh_port
  User $user
  IdentityAgent $agent_socket
  IdentityFile $root/ssh/client.pub
  IdentitiesOnly yes
  UserKnownHostsFile $2
  GlobalKnownHostsFile /dev/null
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  ControlMaster no
EOF
}
write_config "$root/ssh/config" "$root/ssh/known_hosts"
write_config "$root/ssh/unknown_config" "$root/ssh/empty_known_hosts"
for _ in $(seq 1 50); do
  ssh -F "$root/ssh/config" -o BatchMode=yes snippets-fixture true 2>/dev/null && break
  sleep 0.1
done
ssh -F "$root/ssh/config" -o BatchMode=yes snippets-fixture true

export SNIPPETS_GIT_LIVE_HTTP_URL="http://127.0.0.1:$port/library.git"
export SNIPPETS_GIT_LIVE_HTTP_USERNAME=tester
export SNIPPETS_GIT_LIVE_HTTP_TOKEN_FILE=$root/token
export SNIPPETS_GIT_LIVE_SSH_LOCATION="snippets-fixture:$root/repos/library.git"
export SNIPPETS_GIT_LIVE_SSH_PLAIN_LOCATION="snippets-fixture:$root/repos/plain.git"
export SNIPPETS_GIT_LIVE_SSH_PLAIN_REPO=$root/repos/plain.git
export SNIPPETS_GIT_LIVE_SSH_CONFIG=$root/ssh/config
export SNIPPETS_GIT_LIVE_SSH_UNKNOWN_HOST_CONFIG=$root/ssh/unknown_config
status=0
"$test_binary" --exact git_tests::live_http_token_transport --ignored --test-threads=1 || status=$?
if [[ $status == 0 ]]; then
  "$test_binary" --exact git_tests::live_system_ssh_transport --ignored --test-threads=1 || status=$?
fi
if [[ $(login_keyrings) != "$keyrings_before" ]]; then
  printf '%s\n' 'The login keyring directory changed during the fixture run.' >&2
  exit 1
fi
[[ $status == 0 ]] || exit "$status"
# The token reached the server only in Authorization headers: never a URL,
# argv or the repository.
if grep -rqF "$(cat "$root/token")" "$root/http/library.git" "$root/repos/library.git" "$root/repos/plain.git"; then
  printf '%s\n' 'token found in a repository' >&2
  exit 1
fi
printf '%s\n' 'git sync live transports: ok'
