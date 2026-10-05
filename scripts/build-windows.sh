#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
if [[ $# -ne 0 ]]; then
    echo "Usage: $0 (outputs dist/skynet-windows-x64.zip)" >&2
    exit 2
fi
for tool in docker zip; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo 'Please start Docker Desktop first.' >&2; exit 1; }
for source in vendor/skynet/skynet-src/skynet_main.c vendor/lua-cjson/lua_cjson.c; do
    [[ -f "$source" ]] || { echo 'Run git submodule update --init --recursive first.' >&2; exit 1; }
done
mkdir -p dist
STAGE=$(mktemp -d "$ROOT/dist/.windows-build.XXXXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
docker buildx build --platform linux/amd64 --file Dockerfile.windows \
    --output "type=local,dest=$STAGE" "$ROOT"
(cd "$STAGE" && zip -qr skynet-windows-x64.zip skynet-windows-x64)
# Publish only after both compilation and archive creation succeed.
rm -rf -- "$ROOT/dist/skynet-windows-x64"
mv -- "$STAGE/skynet-windows-x64" "$ROOT/dist/"
mv -f -- "$STAGE/skynet-windows-x64.zip" "$ROOT/dist/"
echo 'Ready: dist/skynet-windows-x64.zip'
echo 'Extract the entire folder on Windows x64 and double-click start.bat.'
