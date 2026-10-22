#!/bin/sh
# Shared by Linux Docker entrypoints; the daemon may be remote.
skynet_linux_platform() {
    if [ -z "${SKYNET_PLATFORM:-}" ]; then
        daemon_arch=$(docker info --format '{{.Architecture}}')
        case "$daemon_arch" in
            arm64|aarch64) SKYNET_PLATFORM=linux/arm64 ;;
            amd64|x86_64) SKYNET_PLATFORM=linux/amd64 ;;
            *) echo "Unsupported Docker daemon architecture: $daemon_arch" >&2; return 2 ;;
        esac
    fi
    case "$SKYNET_PLATFORM" in
        linux/arm64) SKYNET_ARCH=arm64 ;;
        linux/amd64) SKYNET_ARCH=amd64 ;;
        *) echo "Unsupported SKYNET_PLATFORM: $SKYNET_PLATFORM (use linux/arm64 or linux/amd64)" >&2; return 2 ;;
    esac
    export SKYNET_PLATFORM SKYNET_ARCH
}
skynet_check_image_platform() {
    actual_platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$1") || return
    if [ "$actual_platform" != "$SKYNET_PLATFORM" ]; then
        echo "Image $1 has platform $actual_platform; expected $SKYNET_PLATFORM. Rebuild or select a matching image." >&2
        return 2
    fi
}
