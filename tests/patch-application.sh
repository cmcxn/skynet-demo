#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/.build"
TMP=$(mktemp -d "$ROOT/.build/patch-check.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
# Deliberately nest this fixture beneath the main repository and use pristine
# committed sources, so parent-repository discovery and stale overlays are tested.
for f in lualib-src/ltls.c lualib/http/httpc.lua lualib/http/internal.lua lualib/http/tlshelper.lua lualib/http/websocket.lua; do
    mkdir -p "$TMP/$(dirname "$f")"
    git -C "$ROOT/vendor/skynet" show "HEAD:$f" > "$TMP/$f"
done
sh "$ROOT/scripts/apply-skynet-patches.sh" "$TMP"
test -f "$TMP/lualib/http/proxy.lua"
grep -q 'SSL_VERIFY_PEER' "$TMP/lualib-src/ltls.c"
grep -q 'proxy.select' "$TMP/lualib/http/httpc.lua"
grep -q 'origin.host' "$TMP/lualib/http/websocket.lua"
grep -q 'HTTP DNS resolution timeout' "$TMP/lualib/http/httpc.lua"
FIRST=$(find "$TMP" -type f -exec cksum {} \; | sort)
sh "$ROOT/scripts/apply-skynet-patches.sh" "$TMP"
SECOND=$(find "$TMP" -type f -exec cksum {} \; | sort)
test "$FIRST" = "$SECOND"
echo 'PASS: pristine nested patch application and idempotent reapplication'
