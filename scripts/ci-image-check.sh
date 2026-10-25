#!/bin/sh
# Offline checks of the installed image, never real model or database credentials.
set -eu
image=${1:?usage: ci-image-check.sh IMAGE}
arch=${SKYNET_ARCH:-amd64}
case "$arch" in amd64|arm64) ;; *) echo "Unsupported architecture" >&2; exit 2;; esac
cd "$(dirname "$0")/.."
test "$(docker image inspect --format '{{.Architecture}}' "$image")" = "$arch"
test "$(docker image inspect --format '{{.Config.User}}' "$image")" = 1000:1000
docker run --rm --platform "linux/$arch" -e SKYNET_ARCH="$arch" \
    -v "$PWD:/workspace:ro" --entrypoint sh "$image" /workspace/tests/linux-runtime-check.sh
docker run --rm --platform "linux/$arch" --entrypoint sh "$image" -ec '
    export LUA_PATH="./lualib/?.lua;./lualib/?/init.lua;;"
    export LUA_CPATH="./luaclib/?.so;;"
    ./3rd/lua/lua tests/aoi/unit.lua
    for license in licenses/skynet/LICENSE licenses/skynet-llm/LICENSE licenses/pluto-aoi/LICENSE licenses/skynet-postgres/LICENSE licenses/lua-cjson/LICENSE licenses/jemalloc/COPYING licenses/lua/lua.h; do
        test -s "$license"
    done
    # Fail without printing potentially sensitive paths or contents.
    count=$(find /skynet -type f \( -name "*.env" -o -name "id_rsa*" -o -name "id_ed25519*" -o -name "*.key" -o -name "llm-settings.bat" \) | wc -l)
    test "$count" -eq 0
    test ! -e /skynet/.git
    test ! -e /skynet/.local
'
container=$(docker run -d -i --platform "linux/$arch" "$image")
trap 'docker rm -f "$container" >/dev/null' EXIT HUP INT TERM
attempt=0
until docker exec "$container" timeout 15 sh tests/run-demo.sh; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 15 ]; then exit 1; fi
    sleep 1
done
