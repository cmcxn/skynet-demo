#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
RUNTIME=${1:-"$ROOT/.build/runtime"}
RUNTIME=$(CDPATH= cd -- "$RUNTIME" && pwd)
export LUA_PATH="$RUNTIME/lualib/?.lua;;"
"$RUNTIME/3rd/lua/lua" tests/proxy-unit.lua "$RUNTIME/luaclib/client.so"
"$RUNTIME/3rd/lua/lua" tests/httpc-unit.lua
"$RUNTIME/3rd/lua/lua" tests/tlshelper-unit.lua
"$RUNTIME/3rd/lua/lua" tests/websocket-unit.lua
"$RUNTIME/3rd/lua/lua" tests/httpc-tls-unit.lua
python3 tests/proxy-integration.py --runtime "$RUNTIME"
