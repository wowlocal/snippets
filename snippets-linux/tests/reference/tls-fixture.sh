#!/usr/bin/env bash
# Development-only generator. All resulting keys are PUBLIC FICTIONAL fixtures.
# Normal Cargo verification consumes the checked-in DER files without OpenSSL.
set -euo pipefail
TASK_TLS_TEMP=$(mktemp -d /tmp/snippets-linux-tls.XXXXXX)
TASK_TLS_FIXTURES=$(cd -- "$(dirname -- "$0")/../fixtures" && pwd)
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj '/CN=Snippets public test CA' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout "$TASK_TLS_TEMP/ca.key" -out "$TASK_TLS_TEMP/ca.pem" 2>/dev/null
openssl req -new -newkey rsa:2048 -nodes -subj '/CN=localhost' \
  -keyout "$TASK_TLS_TEMP/server.key" -out "$TASK_TLS_TEMP/server.csr" 2>/dev/null
cat > "$TASK_TLS_TEMP/server.ext" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
EXT
openssl x509 -req -in "$TASK_TLS_TEMP/server.csr" \
  -CA "$TASK_TLS_TEMP/ca.pem" -CAkey "$TASK_TLS_TEMP/ca.key" -CAcreateserial \
  -days 3650 -extfile "$TASK_TLS_TEMP/server.ext" -out "$TASK_TLS_TEMP/server.pem" 2>/dev/null
openssl x509 -in "$TASK_TLS_TEMP/ca.pem" -outform DER -out "$TASK_TLS_FIXTURES/loopback-ca.der"
openssl x509 -in "$TASK_TLS_TEMP/server.pem" -outform DER -out "$TASK_TLS_FIXTURES/loopback-server.der"
openssl pkcs8 -topk8 -nocrypt -in "$TASK_TLS_TEMP/server.key" -outform DER -out "$TASK_TLS_FIXTURES/loopback-public-test-key.der"
# Temporary public generator inputs are deliberately disposable; no system trust,
# keyring, desktop configuration or application data is changed.
