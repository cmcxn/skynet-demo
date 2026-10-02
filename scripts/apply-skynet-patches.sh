#!/bin/sh
# Apply the checked-in patch to a disposable Skynet build tree, never the submodule.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TARGET=${1:?usage: apply-skynet-patches.sh /path/to/skynet-build-tree}
PATCH="$ROOT/patches/skynet-http-proxy-verified-tls.patch"
if patch -d "$TARGET" -p1 --reverse --dry-run --force --fuzz=0 < "$PATCH" >/dev/null 2>&1; then
    echo 'Skynet proxy/TLS patch already applied'
else
    patch -d "$TARGET" -p1 --dry-run --force --fuzz=0 < "$PATCH"
    patch -d "$TARGET" -p1 --force --fuzz=0 < "$PATCH"
    echo 'Applied Skynet proxy/TLS patch'
fi
