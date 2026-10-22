#!/bin/sh
# Isolated disposable database; never uses application credentials or a host volume.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. ./scripts/linux-platform.sh
skynet_linux_platform
IMAGE=${PG_TEST_IMAGE:-skynet-postgres-demo:dev-$SKYNET_ARCH}
DB_IMAGE=${PG_DB_TEST_IMAGE:-pgvector/pgvector:pg16@sha256:7b822b0aac60967beb1ea5e576b8602c94c300a157d187f385ae3e0da199b90a}
TOOLS=${PG_TEST_TOOLS_IMAGE:-skynet-postgres-test-tools:dev-$SKYNET_ARCH}
if [ "${PG_SKIP_TOOLS_BUILD:-0}" != 1 ]; then
  docker build --platform "$SKYNET_PLATFORM" -f components/skynet-postgres/tests/Dockerfile.tools -t "$TOOLS" .
else
  skynet_check_image_platform "$TOOLS"
fi
if [ "${PG_SKIP_BUILD:-0}" != 1 ]; then docker build --platform "$SKYNET_PLATFORM" -t "$IMAGE" .; else skynet_check_image_platform "$IMAGE"; fi
mkdir -p .local/postgres-results
RUN_DIR=$(mktemp -d "$ROOT/.local/postgres-run.XXXXXX")
TAG="skynet-pg-test-$$"
cleanup() {
  docker rm -f "$TAG-db" "$TAG-fault" >/dev/null 2>&1 || true
  docker network rm "$TAG" >/dev/null 2>&1 || true
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT HUP INT TERM
chmod 755 "$RUN_DIR"
docker run --platform "$SKYNET_PLATFORM" --rm -v "$RUN_DIR:/fixtures" -v "$ROOT:/workspace:ro" --entrypoint sh "$TOOLS" /workspace/components/skynet-postgres/tests/generate-certs.sh /fixtures
# Postgres requires a private key owned by its UID; prepare it inside the disposable container.
docker network create "$TAG" >/dev/null
docker run --platform "$SKYNET_PLATFORM" -d --name "$TAG-db" --network "$TAG" --network-alias db.test -v "$RUN_DIR:/fixtures:ro" \
  -e POSTGRES_PASSWORD=temporary-test-password -e POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 \
  --entrypoint sh "$DB_IMAGE" -ec 'cp /fixtures/server.key /tmp/server.key; chown postgres /tmp/server.key; chmod 600 /tmp/server.key; exec /usr/local/bin/docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/fixtures/server.crt -c ssl_key_file=/tmp/server.key -c password_encryption=scram-sha-256' >/dev/null
ready=0
for attempt in $(seq 1 60); do
  if docker exec "$TAG-db" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[ "$ready" = 1 ] || { docker logs "$TAG-db"; exit 1; }
docker run --platform "$SKYNET_PLATFORM" -d --name "$TAG-fault" --network "$TAG" -v "$RUN_DIR:/fixtures:ro" -v "$ROOT:/workspace:ro" --entrypoint python3 "$TOOLS" /workspace/components/skynet-postgres/tests/fault-server.py >/dev/null
DB_HOST=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$TAG-db")
FAULT_HOST=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$TAG-fault")
# Production image contains everything required; tests add only Lua scripts and fixtures.
docker run --platform "$SKYNET_PLATFORM" --rm --user 0 --network "$TAG" -v "$ROOT:/workspace:ro" -v "$RUN_DIR:/fixtures:ro" \
  -w /skynet -e "PG_TEST_HOST=$DB_HOST" -e "PG_FAULT_HOST=$FAULT_HOST" --entrypoint sh "$IMAGE" -ec '
  export LUA_PATH="./lualib/?.lua;./lualib/?/init.lua;;"
  export LUA_CPATH="./luaclib/?.so;;"
  ./3rd/lua/lua /workspace/components/skynet-postgres/tests/unit.lua
  timeout 90 ./skynet /workspace/components/skynet-postgres/tests/config
'
if [ -n "${PG_NATIVE_RUNTIME:-}" ]; then
  docker run --platform "$SKYNET_PLATFORM" --rm --network "$TAG" -v "$PG_NATIVE_RUNTIME:/skynet:ro" \
    -v "$ROOT:/workspace:ro" -v "$RUN_DIR:/fixtures:ro" -w /skynet \
    -e "PG_TEST_HOST=$DB_HOST" -e "PG_FAULT_HOST=$FAULT_HOST" --entrypoint sh "$TOOLS" -ec '
      export LUA_PATH="./lualib/?.lua;./lualib/?/init.lua;;" LUA_CPATH="./luaclib/?.so;;"
      ./3rd/lua/lua /workspace/components/skynet-postgres/tests/unit.lua
      timeout 90 ./skynet /workspace/components/skynet-postgres/tests/config
    '
fi
if [ -n "${PG_WINDOWS_RUNTIME:-}" ]; then
  WINE_IMAGE=${PG_WINE_IMAGE:-skynet-wine-test:10.0-amd64}
  mkdir -p "$ROOT/.local/postgres-wineprefix"
  docker run --rm --platform linux/amd64 --network "$TAG" \
    -v "$PG_WINDOWS_RUNTIME:/portable:ro" \
    -v "$ROOT/components/skynet-postgres/tests:/postgres-tests:ro" \
    -v "$RUN_DIR:/fixtures:ro" -v "$ROOT/.local/postgres-wineprefix:/wineprefix" \
    -w /portable -e XDG_RUNTIME_DIR=/tmp -e WINEPREFIX=/wineprefix -e WINEDEBUG=-all \
    -e "PG_TEST_HOST=$DB_HOST" -e "PG_FAULT_HOST=$FAULT_HOST" \
    --entrypoint sh "$WINE_IMAGE" -ec '
      timeout 90 /usr/lib/wine/wine64 wineboot -u
      export LUA_PATH="./lualib/?.lua;./lualib/?/init.lua;;" LUA_CPATH="./luaclib/?.so;;"
      timeout 90 /usr/lib/wine/wine64 /portable/lua.exe /postgres-tests/unit.lua
      timeout 150 /usr/lib/wine/wine64 /portable/skynet.exe "\\postgres-tests\\config-windows"
      timeout 60 /usr/lib/wine/wineserver -w
    '
fi
echo 'PASS: PostgreSQL and pgvector packaged-runtime tests'
