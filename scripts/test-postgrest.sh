#!/bin/sh
# Disposable local spike; mounts source into an existing Skynet runtime image.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IMAGE=${POSTGREST_SKYNET_IMAGE:-skynet-demo:master-64391f7}
DB_IMAGE=${POSTGREST_DB_IMAGE:-postgres:16-alpine}
REST_IMAGE=${POSTGREST_IMAGE:-postgrest/postgrest:v12.2.12}
TAG="skynet-postgrest-test-$$"
cleanup() {
  docker rm -f "$TAG-rest" "$TAG-db" >/dev/null 2>&1 || true
  docker network rm "$TAG" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
docker network create "$TAG" >/dev/null
docker run -d --name "$TAG-db" --network "$TAG" --network-alias db \
  -e POSTGRES_PASSWORD=local-test-only \
  -v "$ROOT/components/skynet-postgrest/tests/init.sql:/docker-entrypoint-initdb.d/init.sql:ro" "$DB_IMAGE" >/dev/null
ready=0
for attempt in $(seq 1 60); do
  if docker exec "$TAG-db" psql -U postgres -tAc "SELECT to_regclass('public.skynet_postgrest_test_20261026')" 2>/dev/null | command grep -q skynet_postgrest_test_20261026; then ready=1; break; fi
  sleep 1
done
[ "$ready" = 1 ] || { docker logs "$TAG-db"; exit 1; }
docker run -d --name "$TAG-rest" --network "$TAG" \
  -e PGRST_DB_URI=postgres://postgres:local-test-only@db:5432/postgres \
  -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=web_anon "$REST_IMAGE" >/dev/null
ready=0
for attempt in $(seq 1 30); do
  if docker logs "$TAG-rest" 2>&1 | command grep -q 'Schema cache loaded'; then ready=1; break; fi
  sleep 1
done
[ "$ready" = 1 ] || { docker logs "$TAG-rest"; exit 1; }
# Share the REST container network namespace so profile localhost is stable.
python3 "$ROOT/scripts/test-postgrest-config.py" "$ROOT/.local/postgrest-local.env" --network "container:$TAG-rest"
