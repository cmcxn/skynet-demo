#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
cat > "$tmp/docker" <<'DOCKER'
#!/bin/sh
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1 $2" in
  'info --format') echo "${FAKE_DAEMON_ARCH:-aarch64}" ;;
  'image inspect')
    case "$*" in
      *bad-tools*) echo linux/amd64 ;;
      *) echo "${FAKE_IMAGE_PLATFORM:-linux/arm64}" ;;
    esac ;;
  'inspect -f') echo 127.0.0.1 ;;
esac
DOCKER
chmod +x "$tmp/docker"
export PATH="$tmp:$PATH" DOCKER_LOG="$tmp/log"
unset SKYNET_PLATFORM SKYNET_IMAGE
sh scripts/build-linux.sh
grep -q 'buildx build --platform linux/arm64 --load -t skynet-demo:master-64391f7-arm64' "$DOCKER_LOG"
: > "$DOCKER_LOG"
FAKE_DAEMON_ARCH=x86_64 sh scripts/build-linux.sh
grep -q 'linux/amd64 --load -t skynet-demo:master-64391f7-amd64' "$DOCKER_LOG"
if SKYNET_PLATFORM=linux/riscv64 sh scripts/build-linux.sh >/dev/null 2>&1; then exit 1; fi
if FAKE_DAEMON_ARCH=riscv64 sh scripts/build-linux.sh >/dev/null 2>&1; then exit 1; fi
: > "$DOCKER_LOG"
SKYNET_PLATFORM=linux/arm64 sh scripts/test-llm.sh mock
SKYNET_PLATFORM=linux/arm64 sh scripts/test-postgres.sh
for tag in skynet-llm-demo:dev-arm64 skynet-llm-build:dev-arm64 skynet-llm-test-tools:dev-arm64 skynet-postgres-demo:dev-arm64 skynet-postgres-test-tools:dev-arm64; do
  grep -q "$tag" "$DOCKER_LOG"
done
if grep '^run ' "$DOCKER_LOG" | grep -v -- '--platform linux/arm64'; then exit 1; fi
if grep '^build ' "$DOCKER_LOG" | grep -v -- '--platform linux/arm64'; then exit 1; fi
if SKYNET_PLATFORM=linux/amd64 LLM_SKIP_BUILD=1 sh scripts/test-llm.sh mock >/dev/null 2>&1; then exit 1; fi
if SKYNET_PLATFORM=linux/amd64 PG_SKIP_BUILD=1 PG_SKIP_TOOLS_BUILD=1 sh scripts/test-postgres.sh >/dev/null 2>&1; then exit 1; fi
: > "$DOCKER_LOG"
SKYNET_PLATFORM=linux/amd64 FAKE_IMAGE_PLATFORM=linux/amd64 LLM_SKIP_BUILD=1 LLM_TEST_IMAGE=custom-runtime LLM_TEST_TOOLS_IMAGE=custom-tools sh scripts/test-llm.sh mock
grep -q 'custom-runtime' "$DOCKER_LOG"
grep -q 'custom-tools' "$DOCKER_LOG"
if SKYNET_PLATFORM=linux/arm64 LLM_SKIP_BUILD=1 LLM_TEST_TOOLS_IMAGE=bad-tools sh scripts/test-llm.sh mock >/dev/null 2>&1; then exit 1; fi
if SKYNET_PLATFORM=linux/arm64 PG_SKIP_TOOLS_BUILD=1 PG_TEST_TOOLS_IMAGE=bad-tools sh scripts/test-postgres.sh >/dev/null 2>&1; then exit 1; fi
: > "$DOCKER_LOG"
SKYNET_PLATFORM=linux/amd64 PG_NATIVE_RUNTIME=/fake/native PG_WINDOWS_RUNTIME=/fake/windows PG_TEST_IMAGE=custom-pg PG_TEST_TOOLS_IMAGE=custom-pg-tools PG_DB_TEST_IMAGE=custom-db sh scripts/test-postgres.sh
SKYNET_PLATFORM=linux/amd64 sh scripts/test-llm.sh mock
for tag in skynet-llm-demo:dev-amd64 skynet-llm-build:dev-amd64 skynet-llm-test-tools:dev-amd64 custom-pg custom-pg-tools custom-db; do
  grep -q "$tag" "$DOCKER_LOG"
done
if grep '^run ' "$DOCKER_LOG" | grep -v -- '--platform linux/amd64'; then exit 1; fi
if grep '^build ' "$DOCKER_LOG" | grep -v -- '--platform linux/amd64'; then exit 1; fi
: > "$DOCKER_LOG"
SKYNET_PLATFORM=linux/arm64 SKYNET_IMAGE=custom-build sh scripts/build-linux.sh --no-cache --build-arg EXAMPLE=value
grep -q 'linux/arm64 --load -t custom-build --no-cache --build-arg EXAMPLE=value' "$DOCKER_LOG"
for option in '--platform=linux/amd64' '--platform' '-t' '-tother' '--tag' '--tag=other'; do
  if SKYNET_PLATFORM=linux/arm64 sh scripts/build-linux.sh "$option" >/dev/null 2>&1; then
    echo "Unexpectedly accepted reserved option: $option" >&2
    exit 1
  fi
done
: > "$DOCKER_LOG"
printf 'LLM_API_KEY=fake\n' > "$tmp/model.env"
# Fake Docker cannot write a report, so real mode intentionally exits nonzero.
if SKYNET_PLATFORM=linux/arm64 LLM_RESULTS_DIR="$tmp/results/arm64" LLM_SKIP_BUILD=1 LLM_TEST_ENV="$tmp/model.env" sh scripts/test-llm.sh real >/dev/null 2>&1; then exit 1; fi
grep -q "$tmp/results/arm64:/results" "$DOCKER_LOG"
: > "$DOCKER_LOG"
if SKYNET_PLATFORM=linux/amd64 FAKE_IMAGE_PLATFORM=linux/amd64 LLM_RESULTS_DIR="$tmp/results/amd64" LLM_SKIP_BUILD=1 LLM_TEST_ENV="$tmp/model.env" sh scripts/test-llm.sh real >/dev/null 2>&1; then exit 1; fi
grep -q "$tmp/results/amd64:/results" "$DOCKER_LOG"
# A report override must not prevent mock fixtures in a fresh checkout.
fresh="$tmp/fresh"
mkdir -p "$fresh/scripts" "$fresh/tests"
cp scripts/test-llm.sh scripts/linux-platform.sh "$fresh/scripts/"
cp tests/config-llm "$fresh/tests/"
SKYNET_PLATFORM=linux/arm64 LLM_SKIP_BUILD=1 LLM_RESULTS_DIR="$tmp/external-results" sh "$fresh/scripts/test-llm.sh" mock
echo 'PASS: Linux platform entrypoints'
