#!/bin/sh
# Reproducible native equivalent of Dockerfile; source submodules stay unchanged.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
BUILD=${BUILD_DIR:-"$ROOT/.build"}
OUT=${1:-"$BUILD/runtime"}
PLATFORM=${PLATFORM:-linux}
TLS_INC=${TLS_INC:-/usr/include}
TLS_LIB=${TLS_LIB:-/usr/lib/x86_64-linux-gnu}
JOBS=${JOBS:-4}
mkdir -p "$BUILD" "$OUT"
BUILD=$(CDPATH= cd -- "$BUILD" && pwd)
OUT=$(CDPATH= cd -- "$OUT" && pwd)
# Always start from a fresh source snapshot. Reusing a patched tree can leave
# patch-added files behind when pristine vendor files are copied over it.
SOURCE=$(mktemp -d "$BUILD/sources.XXXXXX")
trap 'rm -rf "$SOURCE"' EXIT HUP INT TERM
mkdir -p "$SOURCE/skynet" "$SOURCE/lua-cjson"
# Exclude VCS metadata: patches apply only to the build copy.
(cd "$ROOT/vendor/skynet" && tar --exclude=.git -cf - .) | (cd "$SOURCE/skynet" && tar -xf -)
(cd "$ROOT/vendor/lua-cjson" && tar --exclude=.git -cf - .) | (cd "$SOURCE/lua-cjson" && tar -xf -)
# Remove host/other-platform outputs from the disposable source snapshot.
find "$SOURCE/skynet" "$SOURCE/lua-cjson" -type f \( -name '*.o' -o -name '*.a' -o -name '*.so' -o -name '*.dll' -o -name '*.exe' \) -delete
sh "$ROOT/scripts/apply-skynet-patches.sh" "$SOURCE/skynet"
patch -d "$SOURCE/skynet" -p1 < "$ROOT/components/skynet-llm/patches/skynet-socket-flow-control.patch"
sh "$ROOT/scripts/check-ca-trust.sh"
make -C "$SOURCE/skynet" "$PLATFORM" -j"$JOBS" TLS_MODULE=ltls TLS_LIB="$TLS_LIB" TLS_INC="$TLS_INC"
make -C "$SOURCE/lua-cjson" LUA_VERSION=5.5 LUA_INCLUDE_DIR="$SOURCE/skynet/3rd/lua" CJSON_CFLAGS='-fpic -pthread -DMULTIPLE_THREADS' CJSON_LDFLAGS='-shared -pthread -lm'
mkdir -p "$OUT/3rd/lua" "$OUT/tests/client" "$OUT/lualib-src"
cp "$SOURCE/skynet/skynet" "$OUT/"
cp -R "$SOURCE/skynet/cservice" "$SOURCE/skynet/luaclib" "$SOURCE/skynet/lualib" "$SOURCE/skynet/service" "$SOURCE/skynet/examples" "$OUT/"
cp "$SOURCE/skynet/3rd/lua/lua" "$OUT/3rd/lua/"
cp -R "$ROOT/tests/." "$OUT/tests/"
cp "$SOURCE/skynet/lualib-src/lua-clientsocket.c" "$OUT/lualib-src/"
cp "$SOURCE/lua-cjson/cjson.so" "$OUT/luaclib/"
cp -R "$SOURCE/lua-cjson/lua/cjson" "$OUT/lualib/"
${CC:-cc} -O2 -fPIC -shared -I"$SOURCE/skynet/3rd/lua" "$OUT/tests/client-socket.c" -o "$OUT/tests/client/socket.so" -lpthread
make -B -C "$ROOT/components/skynet-llm" LUA_INC="$SOURCE/skynet/3rd/lua" OUT_DIR="$OUT/luaclib" OPENSSL_CFLAGS="-I$TLS_INC" OPENSSL_LIBS="-L$TLS_LIB -lssl -lcrypto"
cp -R "$ROOT/components/skynet-llm/lualib/." "$OUT/lualib/"
cp -R "$ROOT/components/skynet-llm/service/." "$OUT/service/"
printf '\nenablessl = true\n'  >> "$OUT/examples/config"
printf 'Native runtime: %s\n' "$OUT"
