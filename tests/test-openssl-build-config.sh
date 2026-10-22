#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
[ -f "$ROOT/scripts/openssl-build-config.sh" ] || { echo 'FAIL: OpenSSL build resolver is missing' >&2; exit 1; }
mkdir -p "$TMP/bin" "$TMP/include/openssl" "$TMP/lib" "$TMP/probes"
printf '/* fixture header */\n' > "$TMP/include/openssl/ssl.h"
# Fake discovery is needed to cover both target architectures on any test host.
cat > "$TMP/bin/pkg-config" <<'TOOL'
#!/bin/sh
[ "${NO_PKG:-0}" = 0 ] || exit 1
case "$*" in
'--variable=includedir openssl') echo "$FIXTURE/include" ;;
'--variable=libdir openssl') echo "$FIXTURE/lib" ;;
*) exit 1 ;;
esac
TOOL
cat > "$TMP/bin/cc" <<'TOOL'
#!/bin/sh
if [ "${1:-}" = -print-multiarch ]; then echo "${TRIPLET:-aarch64-linux-gnu}"; exit; fi
[ "${BAD_LINK:-0}" = 0 ] || exit 1
# Reject a probe that fails to actually link both OpenSSL libraries.
case " $* " in *' -lssl -lcrypto '*) ;; *) exit 1 ;; esac
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then shift; : > "$1"; fi
  shift
done
TOOL
chmod +x "$TMP/bin/cc" "$TMP/bin/pkg-config"
export FIXTURE="$TMP" PATH="$TMP/bin:$PATH" TMPDIR="$TMP/probes" CC=cc
expect() { want=$1; shift; actual=$(env -u TLS_INC -u TLS_LIB "$@" sh -eu -c ' . "$1"; printf "%s|%s\n" "$TLS_INC" "$TLS_LIB"' sh "$ROOT/scripts/openssl-build-config.sh"); [ "$actual" = "$want" ] || { echo "FAIL: expected $want; got $actual" >&2; exit 1; }; }
expect "$TMP/include|$TMP/lib"
expect "/custom/include|/custom/lib" TLS_INC=/custom/include TLS_LIB=/custom/lib
expect "/custom/include|$TMP/lib" TLS_INC=/custom/include
expect "$TMP/include|/custom/lib" TLS_LIB=/custom/lib
for arch in aarch64-linux-gnu x86_64-linux-gnu; do
  expect "/usr/include|/usr/lib/$arch" NO_PKG=1 TRIPLET="$arch"
done
if env BAD_LINK=1 sh -eu -c '. "$1"' sh "$ROOT/scripts/openssl-build-config.sh" > "$TMP/error" 2>&1; then echo 'FAIL: invalid OpenSSL link accepted' >&2; exit 1; fi
# Sourcing must not replace a caller's cleanup trap; probes leave no files.
sh -eu -c 'trap '\''touch "$2"'\'' EXIT; . "$1"' sh "$ROOT/scripts/openssl-build-config.sh" "$TMP/caller-cleanup"
[ -f "$TMP/caller-cleanup" ] || { echo 'FAIL: caller cleanup trap replaced' >&2; exit 1; }
[ -z "$(ls -A "$TMP/probes")" ] || { echo 'FAIL: leaked compiler probe' >&2; exit 1; }
echo 'OpenSSL build configuration tests passed'
