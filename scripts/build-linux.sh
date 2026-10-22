#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
. ./scripts/linux-platform.sh
skynet_linux_platform
SKYNET_IMAGE=${SKYNET_IMAGE:-skynet-demo:master-64391f7-$SKYNET_ARCH}
# Platform and tags are controlled by the named environment overrides.
for argument do
    case "$argument" in
        --platform|--platform=*) echo 'Use SKYNET_PLATFORM to select the build platform.' >&2; exit 2 ;;
        -t*|--tag|--tag=*) echo 'Use SKYNET_IMAGE to select the image tag.' >&2; exit 2 ;;
    esac
done
docker buildx build --platform "$SKYNET_PLATFORM" --load -t "$SKYNET_IMAGE" "$@" .
