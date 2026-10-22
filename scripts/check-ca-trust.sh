#!/bin/sh
# Debian package gate plus offline verification of every published TLS path.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUNDLE=${1:-/etc/ssl/certs/ca-certificates.crt}
if [ "${CA_CHECK_PACKAGE:-1}" = 1 ]; then
    . /etc/os-release
    case "${ID:-}:${VERSION_CODENAME:-}" in
        debian:bookworm) minimum='20250419~deb12u2' ;;
        debian:trixie) minimum='20250419+deb13u1' ;;
        debian:forky|debian:sid) minimum='20260816+nmu1' ;;
        *) echo 'Unsupported CA package platform; review the distribution security advisory.' >&2; exit 1 ;;
    esac
    version=$(dpkg-query -W -f='${Version}' ca-certificates)
    dpkg --compare-versions "$version" ge "$minimum" || {
        echo "ca-certificates $version is older than fixed version $minimum" >&2; exit 1;
    }
    echo "ca-certificates=$version"
fi
[ -s "$BUNDLE" ] || { echo "Missing CA bundle: $BUNDLE" >&2; exit 1; }
openssl crl2pkcs7 -nocrl -certfile "$BUNDLE" -out /dev/null
# Positive control: an unaffected public anchor must still be trusted.
openssl verify -attime 1792627200 -CAfile "$BUNDLE" \
    -no-CApath -no-CAstore \
    "$ROOT/tests/fixtures/emudhra/trusted-isrg-root-x1.crt" >/dev/null
count=0
for chain in "$ROOT"/tests/fixtures/emudhra/*.pem; do
    [ -f "$chain" ] || { echo 'Missing eMudhra regression chains' >&2; exit 1; }
    # Fixed time prevents expired test leaves from falsely proving distrust.
    if output=$(openssl verify -attime 1792627200 -purpose sslserver \
        -CAfile "$BUNDLE" -no-CApath -no-CAstore -untrusted "$chain" "$chain" 2>&1); then
        echo "UNSAFE: accepted $(basename "$chain")" >&2; exit 1
    fi
    case "$output" in
        *'error 20 at '*': unable to get local issuer certificate'*) ;;
        *) echo "Unexpected verification failure for $chain: $output" >&2; exit 1 ;;
    esac
    count=$((count + 1))
done
[ "$count" -eq 12 ] || { echo "Expected 12 test chains, found $count" >&2; exit 1; }
echo "PASS: rejected all $count compromised TLS certificate paths"
