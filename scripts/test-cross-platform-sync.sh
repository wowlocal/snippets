#!/usr/bin/env bash
set -euo pipefail
umask 077

CLIENT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_WORKTREE="${SNIPPETS_SERVER_WORKTREE:-$(dirname "$CLIENT_DIR")/snippets-server}"
SERVER_DIR="$SERVER_WORKTREE/server"
PG_BIN="${SNIPPETS_POSTGRES_BIN:-/opt/homebrew/opt/postgresql@17/bin}"
JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export JAVA_HOME

for executable in ruby curl jq rg cloudflared xcodebuild xcrun uuidgen openssl adb; do
  command -v "$executable" >/dev/null || { echo "missing executable: $executable" >&2; exit 1; }
done
for executable in initdb pg_ctl createdb psql; do
  test -x "$PG_BIN/$executable" || { echo "missing PostgreSQL executable: $PG_BIN/$executable" >&2; exit 1; }
done
test -d "$SERVER_DIR" || { echo "server worktree not found: $SERVER_DIR" >&2; exit 1; }

RUN_ROOT="$(mktemp -d /tmp/snippets-fourway.XXXXXX)"
chmod 700 "$RUN_ROOT"
PG_PORT="$(ruby -rsocket -e 's=TCPServer.new("127.0.0.1", 0); puts s.addr[1]; s.close')"
EDGE_PORT="$(ruby -rsocket -e 's=TCPServer.new("127.0.0.1", 0); puts s.addr[1]; s.close')"
API_PORT="$(ruby -rsocket -e 's=TCPServer.new("127.0.0.1", 0); puts s.addr[1]; s.close')"
OWNER_PASSWORD="$(openssl rand -hex 24)"
RUNTIME_PASSWORD="$(openssl rand -hex 24)"
EDGE_PID=""
API_TUNNEL_PID=""
API_PID=""
ANDROID_EMULATOR_PID=""
ANDROID_EMULATOR_STARTED=0
IOS_SIMULATOR_STARTED=0
IOS_UDID=""
MACOS_CONFIG_PATH="/tmp/snippets-cross-platform-e2e-macos.json"
MACOS_CONFIG_OWNED=0

cleanup() {
  set +e
  if [[ "$MACOS_CONFIG_OWNED" == 1 && "$MACOS_CONFIG_PATH" == "/tmp/snippets-cross-platform-e2e-macos.json" ]]; then
    rm -f -- "$MACOS_CONFIG_PATH"
  fi
  if [[ -n "$IOS_UDID" ]]; then
    for name in SNIPPETS_CLOUD_E2E SNIPPETS_CLOUD_E2E_SERVER_URL \
      SNIPPETS_CLOUD_E2E_ACCESS_TOKEN SNIPPETS_CLOUD_E2E_SPACE_ID \
      SNIPPETS_CLOUD_E2E_APPLE_PHASE; do
      xcrun simctl spawn "$IOS_UDID" launchctl unsetenv "$name" >/dev/null 2>&1
    done
    if [[ "$IOS_SIMULATOR_STARTED" == 1 ]]; then
      xcrun simctl shutdown "$IOS_UDID" >/dev/null 2>&1
    fi
  fi
  if [[ "$ANDROID_EMULATOR_STARTED" == 1 && -n "$ANDROID_EMULATOR_PID" ]]; then
    "$ADB" emu kill >/dev/null 2>&1
    wait "$ANDROID_EMULATOR_PID" 2>/dev/null
  fi
  for process_id in "$API_PID" "$API_TUNNEL_PID" "$EDGE_PID"; do
    [[ -z "$process_id" ]] || kill "$process_id" >/dev/null 2>&1
  done
  "$PG_BIN/pg_ctl" -D "$RUN_ROOT/pgdata" status >/dev/null 2>&1 && \
    "$PG_BIN/pg_ctl" -D "$RUN_ROOT/pgdata" -m fast stop >/dev/null 2>&1
  if [[ "$RUN_ROOT" == /tmp/snippets-fourway.* ]]; then
    rm -rf -- "$RUN_ROOT"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -e "$MACOS_CONFIG_PATH" ]]; then
  echo "refusing to overwrite an existing macOS E2E configuration: $MACOS_CONFIG_PATH" >&2
  exit 1
fi

wait_origin() {
  local log_path="$1"
  local origin=""
  for _ in $(seq 1 90); do
    origin="$(rg -o 'https://[a-z0-9-]+\.trycloudflare\.com' "$log_path" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$origin" ]]; then
      printf '%s\n' "$origin"
      return 0
    fi
    sleep 1
  done
  echo "cloudflared did not publish an origin; log: $log_path" >&2
  return 1
}

wait_system_resolution() {
  local origin="$1"
  local hostname="${origin#https://}"
  for attempt in $(seq 1 180); do
    if ruby -rsocket -e 'Socket.getaddrinfo(ARGV.fetch(0), 443)' "$hostname" \
        >/dev/null 2>&1; then
      return 0
    fi
    if (( attempt % 15 == 0 )); then
      echo "Waiting for disposable HTTPS DNS publication ($((attempt * 2))s)"
      dscacheutil -flushcache >/dev/null 2>&1 || true
    fi
    sleep 2
  done
  echo "HTTPS hostname did not become resolvable: $hostname" >&2
  return 1
}

issue_token() {
  ruby "$SERVER_DIR/Scripts/oidc-integration-fixture.rb" token \
    "$RUN_ROOT/oidc.pem" "$OIDC_ORIGIN" snippets-sync-test snippets-fourway-a
}

set_ios_environment() {
  local phase="$1"
  local token="$2"
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_CLOUD_E2E 1
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_CLOUD_E2E_SERVER_URL "$API_ORIGIN"
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_CLOUD_E2E_ACCESS_TOKEN "$token"
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_CLOUD_E2E_SPACE_ID "$SPACE_ID"
  xcrun simctl spawn "$IOS_UDID" launchctl setenv SNIPPETS_CLOUD_E2E_APPLE_PHASE "$phase"
}

run_macos_phase() {
  local phase="$1"
  local token
  token="$(issue_token)"
  echo "macOS phase: $phase"
  jq -n --arg serverURL "$API_ORIGIN" --arg accessToken "$token" \
    --arg spaceID "$SPACE_ID" --arg phase "$phase" \
    '{serverURL: $serverURL, accessToken: $accessToken, spaceID: $spaceID, phase: $phase}' \
    > "$MACOS_CONFIG_PATH"
  chmod 600 "$MACOS_CONFIG_PATH"
  MACOS_CONFIG_OWNED=1
  xcodebuild -quiet -project "$CLIENT_DIR/Snippets.xcodeproj" -scheme Snippets \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath /tmp/snippets-cross-macos-tests-derived \
    CODE_SIGNING_ALLOWED=NO test-without-building \
    -only-testing:'Snippets macOSTests/SnippetsCloudAppIntegrationTests/testCrossPlatformSyncPhase'
}

run_ios_phase() {
  local phase="$1"
  local token
  token="$(issue_token)"
  echo "iOS phase: $phase"
  set_ios_environment "$phase" "$token"
  xcodebuild -quiet -project "$CLIENT_DIR/Snippets.xcodeproj" -scheme 'Snippets iOS' \
    -configuration Debug -destination "platform=iOS Simulator,id=$IOS_UDID" \
    -derivedDataPath /tmp/snippets-cross-ios-tests-derived \
    CODE_SIGNING_ALLOWED=NO test-without-building \
    -only-testing:'Snippets iOSTests/SnippetsCloudAppIntegrationTests/testCrossPlatformSyncPhase'
}

run_android_phase() {
  local phase="$1"
  local token
  token="$(issue_token)"
  echo "Android phase: $phase"
  "$CLIENT_DIR/gradlew" -p "$CLIENT_DIR" :app:connectedDebugAndroidTest \
    -Pandroid.testInstrumentationRunnerArguments.class=com.khm.snippets.android.CloudEndToEndTest \
    -Pandroid.testInstrumentationRunnerArguments.snippetsServerUrl="$API_ORIGIN" \
    -Pandroid.testInstrumentationRunnerArguments.snippetsAccessToken="$token" \
    -Pandroid.testInstrumentationRunnerArguments.snippetsSpaceId="$SPACE_ID" \
    -Pandroid.testInstrumentationRunnerArguments.snippetsPhase="$phase"
}

assert_server_record_shape() {
  local expected_total="$1"
  local expected_live="$2"
  local expected_deleted="$3"
  local token
  token="$(issue_token)"
  curl -fsS -H "Authorization: Bearer $token" \
    "$API_ORIGIN/v1/spaces/$SPACE_ID/changes?limit=50" | \
    jq -e --argjson total "$expected_total" --argjson live "$expected_live" \
      --argjson deleted "$expected_deleted" \
      '(.records | length) == $total
       and ([.records[] | select(.deleted == false)] | length) == $live
       and ([.records[] | select(.deleted == true)] | length) == $deleted
       and .fullSnapshot == true and .hasMore == false' \
      >/dev/null
}

echo "Building macOS, iOS, and Android integration artifacts"
xcodebuild -quiet -project "$CLIENT_DIR/Snippets.xcodeproj" -scheme Snippets \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/snippets-cross-macos-tests-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -quiet -project "$CLIENT_DIR/Snippets.xcodeproj" -scheme 'Snippets iOS' \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/snippets-cross-ios-tests-derived \
  CODE_SIGNING_ALLOWED=NO build-for-testing
"$CLIENT_DIR/gradlew" -p "$CLIENT_DIR" :app:assembleDebug :app:assembleDebugAndroidTest

printf '%s\n' "$OWNER_PASSWORD" > "$RUN_ROOT/owner.pw"
chmod 600 "$RUN_ROOT/owner.pw"
openssl genrsa -out "$RUN_ROOT/oidc.pem" 2048 >/dev/null 2>&1
chmod 600 "$RUN_ROOT/oidc.pem"

echo "Starting disposable PostgreSQL"
"$PG_BIN/initdb" -D "$RUN_ROOT/pgdata" --username=snippets_owner \
  --pwfile="$RUN_ROOT/owner.pw" --auth-local=trust --auth-host=scram-sha-256 >/dev/null
"$PG_BIN/pg_ctl" -D "$RUN_ROOT/pgdata" -l "$RUN_ROOT/postgres.log" \
  -o "-h 127.0.0.1 -p $PG_PORT" start >/dev/null
PGPASSWORD="$OWNER_PASSWORD" "$PG_BIN/createdb" -h 127.0.0.1 -p "$PG_PORT" \
  -U snippets_owner snippets_fourway_test
PGPASSWORD="$OWNER_PASSWORD" "$PG_BIN/psql" -X -v ON_ERROR_STOP=1 \
  -v runtime_password="$RUNTIME_PASSWORD" -h 127.0.0.1 -p "$PG_PORT" \
  -U snippets_owner -d snippets_fourway_test >/dev/null <<'SQL'
CREATE ROLE snippets_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOINHERIT NOBYPASSRLS PASSWORD :'runtime_password';
SQL

export DATABASE_HOST=127.0.0.1 DATABASE_PORT="$PG_PORT" DATABASE_NAME=snippets_fourway_test
export DATABASE_OWNER_USER=snippets_owner DATABASE_OWNER_PASSWORD="$OWNER_PASSWORD"
export DATABASE_RUNTIME_USER=snippets_runtime DATABASE_RUNTIME_PASSWORD="$RUNTIME_PASSWORD"
export DATABASE_TLS_MODE=disable
(cd "$SERVER_DIR" && MIGRATIONS_DIR="$SERVER_DIR/Migrations" swift run snippets-migrate)

ruby "$CLIENT_DIR/scripts/cross-platform-tls-edge.rb" \
  "$RUN_ROOT/oidc.pem" "$EDGE_PORT" "$API_PORT" > "$RUN_ROOT/edge.log" 2>&1 &
EDGE_PID=$!
cloudflared tunnel --no-autoupdate --protocol http2 --url "http://127.0.0.1:$EDGE_PORT" \
  > "$RUN_ROOT/api-tunnel.log" 2>&1 &
API_TUNNEL_PID=$!
API_ORIGIN="$(wait_origin "$RUN_ROOT/api-tunnel.log")"
OIDC_ORIGIN="$API_ORIGIN"
# The tunnel announcement can precede recursive-DNS publication. Querying the macOS
# resolver in that window makes Tailscale's local resolver retain a negative answer.
# Let the public record settle before the first system lookup.
sleep 20
wait_system_resolution "$API_ORIGIN"

export SNIPPETS_ENV=testing BIND_HOST=127.0.0.1 PORT="$API_PORT"
export PUBLIC_BASE_URL="$API_ORIGIN"
SERVER_INSTANCE_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
export SERVER_INSTANCE_ID
export SERVER_VERSION=integration
TOKEN_HMAC_SECRET="$(openssl rand -base64 32 | tr -d '\n')"
IDENTITY_PEPPER="$(openssl rand -base64 32 | tr -d '\n')"
export TOKEN_HMAC_SECRET IDENTITY_PEPPER
export OIDC_ISSUER="$OIDC_ORIGIN" OIDC_JWKS_URL="$OIDC_ORIGIN/jwks"
export OIDC_AUDIENCE=snippets-sync-test OIDC_CLIENT_ID=snippets-integration-test
export OIDC_SCOPES='openid offline_access' OIDC_ALLOWED_ALGORITHMS=RS256
(cd "$SERVER_DIR" && swift build --product snippets-server)
SERVER_BIN="$(cd "$SERVER_DIR" && swift build --show-bin-path)/snippets-server"
"$SERVER_BIN" > "$RUN_ROOT/server.log" 2>&1 &
API_PID=$!

for attempt in $(seq 1 120); do
  if curl --max-time 5 -fsS "$API_ORIGIN/health/ready" 2>/dev/null | \
      jq -e '.status == "ok"' >/dev/null 2>&1; then
    break
  fi
  if (( attempt % 10 == 0 )); then dscacheutil -flushcache >/dev/null 2>&1 || true; fi
  sleep 2
done
curl --max-time 5 -fsS "$API_ORIGIN/health/ready" | jq -e '.status == "ok"' >/dev/null

NO_AUTH_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' --data-binary '{}' "$API_ORIGIN/v1/spaces")"
test "$NO_AUTH_STATUS" = 401
MALFORMED_AUTH_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H 'Authorization: Bearer not-a-jwt' -H 'Content-Type: application/json' \
  --data-binary '{}' "$API_ORIGIN/v1/spaces")"
test "$MALFORMED_AUTH_STATUS" = 401
WRONG_AUDIENCE_TOKEN="$(ruby "$SERVER_DIR/Scripts/oidc-integration-fixture.rb" token \
  "$RUN_ROOT/oidc.pem" "$OIDC_ORIGIN" snippets-wrong-audience snippets-fourway-a)"
WRONG_AUDIENCE_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $WRONG_AUDIENCE_TOKEN" -H 'Content-Type: application/json' \
  --data-binary '{}' "$API_ORIGIN/v1/spaces")"
test "$WRONG_AUDIENCE_STATUS" = 401

TOKEN_A="$(issue_token)"
IDEMPOTENCY="$(uuidgen | tr '[:upper:]' '[:lower:]')"
SPACE_RESPONSE="$(curl -fsS -X POST -H "Authorization: Bearer $TOKEN_A" \
  -H 'Content-Type: application/json' --data-binary "{\"idempotencyKey\":\"$IDEMPOTENCY\"}" \
  "$API_ORIGIN/v1/spaces")"
SPACE_ID="$(jq -er '.spaceId' <<< "$SPACE_RESPONSE")"
REPLAYED_SPACE_ID="$(curl -fsS -X POST -H "Authorization: Bearer $TOKEN_A" \
  -H 'Content-Type: application/json' --data-binary "{\"idempotencyKey\":\"$IDEMPOTENCY\"}" \
  "$API_ORIGIN/v1/spaces" | jq -er '.spaceId')"
test "$REPLAYED_SPACE_ID" = "$SPACE_ID"
curl -fsS -H "Authorization: Bearer $TOKEN_A" \
  "$API_ORIGIN/v1/spaces/$SPACE_ID/changes?limit=50" | \
  jq -e --arg space "$SPACE_ID" '.spaceId == $space and (.records | length) == 0' >/dev/null

TOKEN_B="$(ruby "$SERVER_DIR/Scripts/oidc-integration-fixture.rb" token \
  "$RUN_ROOT/oidc.pem" "$OIDC_ORIGIN" snippets-sync-test snippets-fourway-b)"
OTHER_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN_B" "$API_ORIGIN/v1/spaces/$SPACE_ID/scope")"
test "$OTHER_STATUS" = 404

IOS_UDID="${IOS_SIMULATOR_UDID:-$(xcrun simctl list devices available -j | ruby -rjson -e '
  devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
  device = devices.find { |item| item["name"].start_with?("iPhone") && item["state"] == "Booted" } ||
           devices.find { |item| item["name"].start_with?("iPhone") }
  abort "no available iPhone simulator" unless device
  puts device.fetch("udid")
') }"
IOS_UDID="$(printf '%s' "$IOS_UDID" | tr -d '[:space:]')"
if ! xcrun simctl list devices | rg -F "$IOS_UDID" | rg -q '\(Booted\)'; then
  xcrun simctl boot "$IOS_UDID"
  IOS_SIMULATOR_STARTED=1
fi
xcrun simctl bootstatus "$IOS_UDID" -b

ADB="$(command -v adb)"
ANDROID_SDK="$(cd "$(dirname "$ADB")/.." && pwd)"
if ! "$ADB" devices | awk 'NR > 1 && $2 == "device" { found=1 } END { exit !found }'; then
  EMULATOR="$ANDROID_SDK/emulator/emulator"
  AVD_NAME="$($EMULATOR -list-avds | awk '/medium_phone/ { print; exit }')"
  [[ -n "$AVD_NAME" ]] || AVD_NAME="$($EMULATOR -list-avds | head -n 1)"
  [[ -n "$AVD_NAME" ]] || { echo "no Android AVD is installed" >&2; exit 1; }
  "$EMULATOR" -avd "$AVD_NAME" -no-snapshot-save > "$RUN_ROOT/android-emulator.log" 2>&1 &
  ANDROID_EMULATOR_PID=$!
  ANDROID_EMULATOR_STARTED=1
  "$ADB" wait-for-device
  for _ in $(seq 1 120); do
    [[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && break
    sleep 1
  done
  [[ "$("$ADB" shell getprop sys.boot_completed | tr -d '\r')" == 1 ]]
fi

run_macos_phase mac-seed
assert_server_record_shape 1 1 0
run_ios_phase ios-seed
assert_server_record_shape 2 2 0
run_android_phase contribute
assert_server_record_shape 3 3 0
run_macos_phase mac-update-android
assert_server_record_shape 3 3 0
run_ios_phase ios-update-mac
assert_server_record_shape 3 3 0
run_android_phase verify
run_macos_phase mac-verify
run_ios_phase ios-verify
run_android_phase delete
assert_server_record_shape 3 2 1
run_macos_phase mac-verify-deletion
run_ios_phase ios-verify-deletion
run_android_phase verify-deletion

TOKEN_A="$(issue_token)"
curl -fsS -H "Authorization: Bearer $TOKEN_A" \
  "$API_ORIGIN/v1/spaces/$SPACE_ID/changes?limit=50" | \
  jq -e '(.records | length) == 3
    and ([.records[] | select(.deleted == false)] | length) == 2
    and ([.records[] | select(.deleted == true)] | length) == 1
    and .fullSnapshot == true and .hasMore == false' >/dev/null

DB_SUMMARY="$(PGPASSWORD="$OWNER_PASSWORD" "$PG_BIN/psql" -XAt -h 127.0.0.1 \
  -p "$PG_PORT" -U snippets_owner -d snippets_fourway_test -c "
SELECT count(*), bool_and(
  position(convert_to('snippets-macos-e2e-initial-8d134f53', 'UTF8') in blob) = 0 AND
  position(convert_to('snippets-macos-e2e-final-from-ios-8d134f53', 'UTF8') in blob) = 0 AND
  position(convert_to('snippets-ios-e2e-initial-91a8c211', 'UTF8') in blob) = 0 AND
  position(convert_to('snippets-android-e2e-initial-4f6c77f8', 'UTF8') in blob) = 0 AND
  position(convert_to('snippets-android-e2e-final-from-macos-4f6c77f8', 'UTF8') in blob) = 0)
FROM records;")"
test "$DB_SUMMARY" = "3|t"

RLS_SUMMARY="$(PGPASSWORD="$OWNER_PASSWORD" "$PG_BIN/psql" -XAt -h 127.0.0.1 \
  -p "$PG_PORT" -U snippets_owner -d snippets_fourway_test -c "
SELECT count(*), bool_and(relrowsecurity), bool_and(relforcerowsecurity)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relname IN
('users','identities','spaces','space_memberships','space_creation_requests','records','changes','key_envelopes','pairings');")"
test "$RLS_SUMMARY" = "9|t|t"

RUNTIME_SUMMARY="$(PGPASSWORD="$RUNTIME_PASSWORD" "$PG_BIN/psql" -XAt -h 127.0.0.1 \
  -p "$PG_PORT" -U snippets_runtime -d snippets_fourway_test -c \
  "SELECT current_setting('app.user_id', true) IS NULL, count(*) FROM records;")"
test "$RUNTIME_SUMMARY" = "t|0"

echo "Cross-platform sync passed: server + PostgreSQL + macOS + iOS Simulator + Android"
echo "Final server records: 2 live + 1 tombstone; auth/tenant/idempotency checks passed"
echo "Plaintext probes absent; RLS enabled and forced on all 9 tenant tables"
