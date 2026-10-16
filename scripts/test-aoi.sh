#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
MODE=${1:-native}
case "$MODE" in
native)
    ROOT=$(pwd)
    export AOI_SKYNET_ROOT="$ROOT/vendor/skynet"
    export AOI_TEST_DIR="$ROOT/components/skynet-aoi/tests"
    export AOI_LUALIB="$ROOT/components/skynet-aoi/lualib"
    export AOI_LUACLIB="$ROOT/components/skynet-aoi/luaclib"
    test -x "$AOI_SKYNET_ROOT/skynet" && test -x "$AOI_SKYNET_ROOT/3rd/lua/lua" || {
        echo 'Build vendor/skynet first; see components/skynet-aoi/README.md.' >&2; exit 1;
    }
    command -v timeout >/dev/null || { echo 'GNU timeout is required.' >&2; exit 1; }
    make -C components/skynet-aoi
    "$AOI_SKYNET_ROOT/3rd/lua/lua" "$AOI_TEST_DIR/unit.lua"
    AOI_TEST_RESULT=$(mktemp); export AOI_TEST_RESULT
    trap 'rm -f "$AOI_TEST_RESULT"' EXIT HUP INT TERM
    timeout 30 "$AOI_SKYNET_ROOT/skynet" tests/config-aoi
    test "$(cat "$AOI_TEST_RESULT")" = PASS
    ;;
docker)
    IMAGE=${AOI_TEST_IMAGE:-skynet-aoi-demo:dev}
    if [ "${AOI_SKIP_BUILD:-0}" != 1 ]; then docker build -t "$IMAGE" .; fi
    docker run --rm --entrypoint sh "$IMAGE" -ec '
        export LUA_PATH="./lualib/?.lua;;" LUA_CPATH="./luaclib/?.so;;"
        ./3rd/lua/lua tests/aoi/unit.lua
        export AOI_SKYNET_ROOT=/skynet AOI_TEST_DIR=/skynet/tests/aoi
        export AOI_LUALIB=/skynet/lualib AOI_LUACLIB=/skynet/luaclib
        AOI_TEST_RESULT=$(mktemp); export AOI_TEST_RESULT
        trap '\''rm -f "$AOI_TEST_RESULT"'\'' EXIT HUP INT TERM
        timeout 30 ./skynet tests/config-aoi
        test "$(cat "$AOI_TEST_RESULT")" = PASS
    '
    ;;
*) echo 'Usage: scripts/test-aoi.sh [native|docker]' >&2; exit 2 ;;
esac
echo "PASS: AOI $MODE standalone and Skynet tests"
