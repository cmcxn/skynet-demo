#!/bin/sh
# Run inside the built image; never accepts a host-native module as proof.
set -eu
cd /skynet
case "${SKYNET_ARCH:?set SKYNET_ARCH to arm64 or amd64}" in
    arm64) machine=183 ;;
    amd64) machine=62 ;;
    *) echo 'Unsupported runtime architecture' >&2; exit 2 ;;
esac
check_elf() {
    magic=$(od -An -tx1 -N4 "$1" | tr -d ' \n')
    actual=$(od -An -tu2 -j18 -N2 "$1" | tr -d ' \n')
    [ "$magic" = 7f454c46 ] && [ "$actual" = "$machine" ] || {
        echo "FAIL: $1 is not the expected $SKYNET_ARCH ELF" >&2; exit 1;
    }
    dependencies=$(ldd "$1" 2>&1) || { echo "$dependencies" >&2; exit 1; }
    case "$dependencies" in *'not found'*) echo "$dependencies" >&2; exit 1;; esac
}
check_elf ./skynet
check_elf ./3rd/lua/lua
for module in ./cservice/*.so ./luaclib/*.so ./tests/client/*.so; do
    check_elf "$module"
done
export LUA_PATH='./lualib/?.lua;./lualib/?/init.lua;;'
export LUA_CPATH='./luaclib/?.so;;'
./3rd/lua/lua -e '
    assert(_VERSION == "Lua 5.5", _VERSION)
    for _, name in ipairs {"cjson", "skynet_llm_tls", "skynet_postgres_native"} do
        assert(require(name)); print("PASS: load " .. name)
    end
'
rm -f /tmp/skynet-runtime-load-result
timeout 30 ./skynet /workspace/tests/config-runtime-load
test "$(cat /tmp/skynet-runtime-load-result)" = PASS
echo "PASS: $SKYNET_ARCH runtime ELF, dynamic dependencies and installed modules"
