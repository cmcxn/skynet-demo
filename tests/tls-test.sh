#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
CC=${CC:-cc}
mkdir -p "$TMP/skynet/lualib-src" "$TMP/skynet/lualib/http"
cp "$ROOT/vendor/skynet/lualib-src/ltls.c" "$TMP/skynet/lualib-src/"
cp "$ROOT/vendor/skynet/lualib/http/"*.lua "$TMP/skynet/lualib/http/"
sh "$ROOT/scripts/apply-skynet-patches.sh" "$TMP/skynet"
# onelua avoids changing the vendored checkout or requiring installed Lua headers.
$CC ${CFLAGS:--O1 -g} -std=gnu99 -DMAKE_LIB -DLUA_USE_LINUX \
    -I"$ROOT/vendor/skynet/3rd/lua" -I"$ROOT/vendor/skynet/skynet-src" -I"$TMP/skynet/lualib-src" \
    "$ROOT/vendor/skynet/3rd/lua/onelua.c" "$ROOT/tests/tls-c-runner.c" \
    -o "$TMP/tls-tests" -lssl -lcrypto -lm -ldl
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=TLS-Test-CA \
    -keyout "$TMP/ca.key" -out "$TMP/ca.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=Wrong-Test-CA \
    -keyout "$TMP/wrong-ca.key" -out "$TMP/wrong-ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj /CN=unused.test \
    -keyout "$TMP/server.key" -out "$TMP/server.csr" >/dev/null 2>&1
cat > "$TMP/extensions.cnf" <<'CERT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:tls.test,IP:127.0.0.1,IP:::1
CERT
openssl x509 -req -days 2 -in "$TMP/server.csr" -CA "$TMP/ca.crt" \
    -CAkey "$TMP/ca.key" -CAcreateserial -extfile "$TMP/extensions.cnf" \
    -out "$TMP/server.crt" >/dev/null 2>&1
printf 'not a certificate\n' > "$TMP/bad.pem"
mkdir "$TMP/ca-dir" "$TMP/empty-dir"
cp "$TMP/ca.crt" "$TMP/ca-dir/ca.crt"
openssl rehash "$TMP/ca-dir" >/dev/null 2>&1
SSL_CERT_FILE="$TMP/ca.crt" SSL_CERT_DIR="$TMP/empty-dir" \
    "$TMP/tls-tests" "$ROOT/tests/tls-verification.lua" "$TMP"
SSL_CERT_FILE="$TMP/missing-default.pem" SSL_CERT_DIR="$TMP/ca-dir" \
    TLS_TEST_FILTER="default trust environment" \
    "$TMP/tls-tests" "$ROOT/tests/tls-verification.lua" "$TMP"
