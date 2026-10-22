#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
for arch in arm64 amd64; do
    SKYNET_PLATFORM=linux/$arch SKYNET_IMAGE=skynet-demo:master-64391f7-$arch \
        docker compose config --format json | python3 -c '
import json, sys
s = json.load(sys.stdin)["services"]["skynet"]
arch = sys.argv[1]
assert s["image"] == "skynet-demo:master-64391f7-" + arch, s
assert s["platform"] == "linux/" + arch, s
' "$arch"
done
env -u SKYNET_PLATFORM -u SKYNET_IMAGE docker compose config --format json | python3 -c '
import json, sys
s = json.load(sys.stdin)["services"]["skynet"]
assert s["image"] == "skynet-demo:master-64391f7", s
assert not s.get("platform"), s
'
echo 'PASS: Compose explicit platforms and unchanged daemon default'
