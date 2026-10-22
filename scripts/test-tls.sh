#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
sh tests/tls-test.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/lualib/http" "$TMP/lualib-src"
cp vendor/skynet/lualib/http/*.lua "$TMP/lualib/http/"
cp vendor/skynet/lualib-src/ltls.c vendor/skynet/lualib-src/lua-skynet.c "$TMP/lualib-src/"
patch -d "$TMP" -p1 < patches/skynet-verified-client-tls.patch
LUA=${LUA:-vendor/skynet/3rd/lua/lua}
"$LUA" -e "package.path='$TMP/lualib/?.lua;'..package.path; dofile('tests/websocket-unit.lua')"
"$LUA" -e "package.path='$TMP/lualib/?.lua;'..package.path; dofile('tests/httpc-tls-unit.lua')"
