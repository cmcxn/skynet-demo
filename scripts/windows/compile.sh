#!/usr/bin/env bash
set -euo pipefail
cd /src/skynet
CC=x86_64-w64-mingw32-gcc
COMMON=(-O2 -shared -static-libgcc -I3rd/lua -L3rd/lua)
"$CC" "${COMMON[@]}" -Iskynet-src -I/opt/openssl/include \
    lualib-src/ltls.c -o luaclib/ltls.so -llua54 \
    /opt/openssl/lib64/libssl.a /opt/openssl/lib64/libcrypto.a \
    -lws2_32 -lcrypt32 -lbcrypt
"$CC" "${COMMON[@]}" -DMULTIPLE_THREADS \
    /src/lua-cjson/lua_cjson.c /src/lua-cjson/strbuf.c /src/lua-cjson/fpconv.c \
    -o /src/lua-cjson/cjson.so -llua54 -Wl,-Bstatic -lpthread -Wl,-Bdynamic -lm
mkdir -p /out/tests/client /out/licenses
"$CC" -O2 -static-libgcc -I3rd/compat-mingw /src/windows/test-udp-errno.c \
    3rd/compat-mingw/libcompat.a -static -lpthread -lws2_32 -o /out/tests/udp-errno.exe
"$CC" "${COMMON[@]}" -std=c11 -Wall -Wextra -Werror -I/opt/openssl/include \
    /src/skynet-llm/lualib-src/skynet_llm_tls.c -o /tmp/skynet_llm_tls.so -llua54 \
    /opt/openssl/lib64/libssl.a /opt/openssl/lib64/libcrypto.a \
    -lws2_32 -lcrypt32 -lbcrypt
"$CC" "${COMMON[@]}" -Iskynet-src -I3rd/compat-mingw -include 3rd/compat-mingw/compat.h \
    -Wno-int-conversion -Wno-incompatible-pointer-types \
    tests/client-socket.c -o /out/tests/client/socket.so \
    3rd/compat-mingw/libcompat.a -llua54 -static -lpthread -lws2_32
cp skynet.exe skynet.dll lua54.dll 3rd/lua/lua.exe 3rd/lua/luac.exe /out/
cp -r cservice luaclib lualib service examples /out/
cp /tmp/skynet_llm_tls.so /out/luaclib/
"$CC" "${COMMON[@]}" -std=c11 -Wall -Wextra -Werror -I/opt/openssl/include \
    /src/skynet-postgres/lualib-src/skynet_postgres_native.c -o /out/luaclib/skynet_postgres_native.so -llua54 \
    /opt/openssl/lib64/libssl.a /opt/openssl/lib64/libcrypto.a -lws2_32 -lcrypt32 -lbcrypt -liphlpapi
cp -r /src/skynet-postgres/lualib/. /out/lualib/
mkdir -p /out/licenses/skynet-postgres
cp -r /src/skynet-postgres/licenses /out/licenses/skynet-postgres/
cp /src/skynet-postgres/{LICENSE,SOURCES.md,SOURCE-SHA256.json,README.md} /out/licenses/skynet-postgres/

cp -r /src/skynet-llm/lualib/. /out/lualib/
cp -r /src/skynet-llm/service/. /out/service/
mkdir -p /out/certs /out/tests/llm-unit /out/licenses/skynet-llm
sh /src/security/scripts/check-ca-trust.sh
cp /etc/ssl/certs/ca-certificates.crt /out/certs/ca-bundle.crt
# Check the exact file shipped, then record its package version and digest.
sh /src/security/scripts/check-ca-trust.sh /out/certs/ca-bundle.crt
dpkg-query -W ca-certificates > /out/certs/source-package.txt
(cd /out/certs && sha256sum ca-bundle.crt > SHA256SUMS)
for unit in protocol sse; do
    sed 's@components/skynet-llm/lualib/@lualib/@g' \
        "/src/skynet-llm/tests/unit/$unit.lua" > "/out/tests/llm-unit/$unit.lua"
done
cp /src/windows/llm-smoke.lua /src/windows/config-llm /src/windows/detect-dns.ps1 /out/tests/
# Reuse the same provider checks; only paths and process shutdown differ.
sed -e 's@/results/real.json@llm-real-result.json@g' \
    -e 's@/tmp/skynet-llm-result@llm-test-result.txt@g' \
    -e 's@require("skynet.core").command("ABORT")@os.exit(passed and 0 or 1)@' \
    /src/skynet-llm/tests/integration/real.lua > /out/tests/llm-check.lua
cp /src/skynet-llm/LICENSE /src/skynet-llm/README.md /out/licenses/skynet-llm/
cp /src/skynet-llm/patches/skynet-socket-flow-control.patch /out/licenses/skynet-llm/
cp /src/windows/main.lua /out/examples/main.lua
cp /src/lua-cjson/cjson.so /out/luaclib/
cp -r /src/lua-cjson/lua/cjson /out/lualib/
cp tests/demo-client.lua /out/tests/
cp tests/https-check.lua /out/tests/
for bat in /src/windows/*.bat; do
    sed 's/$/\r/' "$bat" > "/out/$(basename "$bat")"
done
cp /src/windows/README.txt /out/
cp /src/windows/smoke.lua /out/tests/
cp /src/windows/config-https /out/tests/
printf '\nenablessl = true\n' >> /out/examples/config
cp LICENSE /out/licenses/skynet.txt
cat 3rd/lua/README 3rd/lua/lua.h > /out/licenses/lua.txt
cp /src/lua-cjson/LICENSE /out/licenses/lua-cjson.txt
cp /src/openssl/LICENSE.txt /out/licenses/openssl.txt
cp /src/windows/skynet-mingw-udp.patch /out/licenses/skynet-mingw-udp.patch
cp /src/windows/skynet-verified-client-tls.patch /out/licenses/
cp /src/windows/PATCH-SOURCES.md /out/licenses/
cp /usr/share/doc/gcc-mingw-w64-base/copyright /out/licenses/gcc-mingw-w64.txt
cp /usr/share/doc/mingw-w64-common/copyright /out/licenses/mingw-w64.txt

# Bundle every non-system DLL referenced by the EXEs and native modules.
# Re-scan after copying dependencies, so indirect DLL imports are covered too.
while :; do
    added=0
    while IFS= read -r dll; do
        case "${dll,,}" in
            iphlpapi.dll|kernel32.dll|msvcrt.dll|user32.dll|gdi32.dll|ws2_32.dll|advapi32.dll|crypt32.dll|bcrypt.dll|ntdll.dll|secur32.dll|shell32.dll|ole32.dll|ucrtbase.dll|api-ms-win-*.dll) continue ;;
        esac
        [[ -f "/out/$dll" ]] && continue
        dep=$("$CC" -print-file-name="$dll")
        [[ -f "$dep" ]] || dep="/usr/x86_64-w64-mingw32/lib/$dll"
        [[ -f "$dep" ]] || { echo "Unresolved Windows DLL: $dll" >&2; exit 1; }
        cp "$dep" /out/
        added=1
    done < <(find /out -type f \( -name '*.exe' -o -name '*.dll' -o -name '*.so' \) \
        -exec x86_64-w64-mingw32-objdump -p {} + | awk '/DLL Name:/ {print $3}' | sort -u)
    [[ "$added" -eq 1 ]] || break
done
# All .so files are Windows PE DLLs; Skynet's Lua paths retain that suffix.
find /out -type f \( -name '*.exe' -o -name '*.dll' -o -name '*.so' \) \
    -exec x86_64-w64-mingw32-objdump -f {} + > /out/native-files.txt
if ! awk '/file format/ {count++; if ($NF != "pei-x86-64") bad=1} END {exit (bad || !count)}' /out/native-files.txt; then
    echo 'Non-Windows-x64 binary found in Windows package' >&2
    exit 1
fi
