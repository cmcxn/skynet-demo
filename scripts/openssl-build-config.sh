#!/bin/sh
# Source in the target build environment, not on the Docker host.
# Explicit TLS_INC/TLS_LIB take precedence over discovery.
openssl_build_config() {
    openssl_pkg_config=${PKG_CONFIG:-pkg-config}
    if [ -z "${TLS_INC:-}" ]; then
        TLS_INC=$($openssl_pkg_config --variable=includedir openssl 2>/dev/null) || TLS_INC=
        TLS_INC=${TLS_INC:-/usr/include}
    fi
    if [ -z "${TLS_LIB:-}" ]; then
        TLS_LIB=$($openssl_pkg_config --variable=libdir openssl 2>/dev/null) || TLS_LIB=
        if [ -z "$TLS_LIB" ]; then
            openssl_multiarch=$(${CC:-cc} -print-multiarch 2>/dev/null) || openssl_multiarch=
            case "$openssl_multiarch" in
                ''|*[!a-zA-Z0-9_-]*) TLS_LIB=/usr/lib ;;
                *) TLS_LIB=/usr/lib/$openssl_multiarch ;;
            esac
        fi
    fi
    OPENSSL_CFLAGS="-I$TLS_INC"
    OPENSSL_LIBS="-L$TLS_LIB -lssl -lcrypto"
    # A subshell owns cleanup so sourcing does not overwrite the caller's trap.
    if ! (
        openssl_probe=$(mktemp -d "${TMPDIR:-/tmp}/skynet-openssl.XXXXXX") || exit 1
        trap 'rm -rf "$openssl_probe"' EXIT
        trap 'exit 1' HUP INT TERM
        cat > "$openssl_probe/check.c" <<'PROBE'
#include <openssl/ssl.h>
#include <openssl/crypto.h>
int main(void) {
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    SSL_CTX_free(ctx);
    return OpenSSL_version_num() == 0;
}
PROBE
        # Match the compiler and directory flags used by Skynet; link, do not
        # execute, so this check also works with a cross compiler.
        ${CC:-cc} ${CPPFLAGS:-} ${CFLAGS:-} -I"$TLS_INC" "$openssl_probe/check.c" \
            ${LDFLAGS:-} -L"$TLS_LIB" -lssl -lcrypto -o "$openssl_probe/check"
    ); then
        printf 'OpenSSL headers/libraries are not usable with %s (TLS_INC=%s TLS_LIB=%s). Install libssl-dev/pkg-config or set TLS_INC and TLS_LIB.\n' "${CC:-cc}" "$TLS_INC" "$TLS_LIB" >&2
        return 1
    fi
    export TLS_INC TLS_LIB OPENSSL_CFLAGS OPENSSL_LIBS
}
openssl_build_config
