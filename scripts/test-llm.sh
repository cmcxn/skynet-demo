#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TASK_ROOT=$(pwd)
MODE=${1:-mock}
case "$MODE" in mock|real|all) ;; *) echo 'Usage: scripts/test-llm.sh [mock|real|all]' >&2; exit 2;; esac
LLM_TEST_IMAGE=${LLM_TEST_IMAGE:-skynet-llm-demo:dev}
if [ "${LLM_SKIP_BUILD:-0}" != 1 ]; then
    docker build -t "$LLM_TEST_IMAGE" .
    if [ "$MODE" != real ]; then
        docker build --target build -t skynet-llm-build:dev .
        docker build -f components/skynet-llm/tests/Dockerfile.tools -t skynet-llm-test-tools:dev .
    fi
fi
mkdir -p .local/llm-results
NETWORK="skynet-llm-test-$$"
MOCK_CONTAINER="skynet-llm-fixture-$$"
LLM_RUN_DIR=
cleanup() {
    docker rm -f "$MOCK_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    case "$LLM_RUN_DIR" in
        "$TASK_ROOT"/.local/llm-run.*) rm -rf -- "$LLM_RUN_DIR" ;;
    esac
}
trap cleanup EXIT HUP INT TERM
if [ "$MODE" != real ]; then
    LLM_RUN_DIR=$(mktemp -d "$TASK_ROOT/.local/llm-run.XXXXXX")
    mkdir "$LLM_RUN_DIR/fixtures"
    chmod 755 "$LLM_RUN_DIR" "$LLM_RUN_DIR/fixtures"
    sed 's@/workspace/\.local/llm-fixtures/ca\.pem@/fixtures/ca.pem@' \
        tests/config-llm > "$LLM_RUN_DIR/config-llm"
    chmod 644 "$LLM_RUN_DIR/config-llm"
    LLM_MOCK_CONFIG="/workspace/${LLM_RUN_DIR#"$TASK_ROOT"/}/config-llm"
    docker run --rm -v "$LLM_RUN_DIR/fixtures:/fixtures" \
        -v "$TASK_ROOT/components/skynet-llm/tests:/tests:ro" --entrypoint sh \
        skynet-llm-test-tools:dev /tests/generate_certs.sh /fixtures
    docker network create "$NETWORK" >/dev/null
    docker run -d --name "$MOCK_CONTAINER" --network "$NETWORK" --network-alias mock --network-alias wronghost \
        -v "$LLM_RUN_DIR/fixtures:/fixtures:ro" \
        -v "$TASK_ROOT/components/skynet-llm/tests:/tests:ro" --entrypoint python3 \
        skynet-llm-test-tools:dev -u /tests/mock_server.py >/dev/null
    docker run --rm --network "$NETWORK" --entrypoint python3 skynet-llm-test-tools:dev -c '
import time,urllib.request
for attempt in range(30):
    try:
        urllib.request.urlopen("http://mock:18080/",timeout=1).read()
        break
    except OSError:
        time.sleep(0.1)
else:
    raise SystemExit("fixture did not become ready")
'
    for unit in protocol sse; do
        docker run --rm --user 0 -v "$TASK_ROOT:/workspace:ro" \
            -v "$LLM_RUN_DIR/fixtures:/fixtures:ro" -w /workspace \
            --entrypoint /skynet/3rd/lua/lua "$LLM_TEST_IMAGE" "components/skynet-llm/tests/unit/$unit.lua"
    done
    for service in transport client lifecycle; do
        docker run --rm --user 0 --network "$NETWORK" -v "$TASK_ROOT:/workspace:ro" \
            -v "$LLM_RUN_DIR/fixtures:/fixtures:ro" -w /skynet \
            -e "LLM_TEST_SERVICE=integration/$service" -e "LLM_TEST_CONFIG=$LLM_MOCK_CONFIG" \
            --entrypoint sh "$LLM_TEST_IMAGE" \
            -c 'timeout 90 ./skynet "$LLM_TEST_CONFIG" && test "$(cat /tmp/skynet-llm-result)" = PASS'
    done
    # Verify the installed modules and C extension as well as the source mount.
    sed -e 's@/workspace/components/skynet-llm/service/?.lua;@@' \
        -e 's@/workspace/components/skynet-llm/lualib/?.lua;@@' \
        -e 's@/workspace/components/skynet-llm/luaclib/?.so;@@' \
        "$LLM_RUN_DIR/config-llm" > "$LLM_RUN_DIR/config-llm-installed"
    chmod 644 "$LLM_RUN_DIR/config-llm-installed"
    for service in client transport; do
        docker run --rm --user 1000:1000 --network "$NETWORK" -v "$TASK_ROOT:/workspace:ro" \
            -v "$LLM_RUN_DIR/fixtures:/fixtures:ro" -w /skynet \
            -e "LLM_TEST_SERVICE=integration/$service" -e "LLM_TEST_CONFIG=${LLM_MOCK_CONFIG}-installed" \
            --entrypoint sh "$LLM_TEST_IMAGE" \
            -c 'timeout 90 ./skynet "$LLM_TEST_CONFIG" && test "$(cat /tmp/skynet-llm-result)" = PASS'
    done
    for example in chat chat_tools responses_tools streaming embeddings; do
        docker run --rm --user 0 --network "$NETWORK" -v "$TASK_ROOT:/workspace:ro" \
            -v "$LLM_RUN_DIR/fixtures:/fixtures:ro" -w /skynet \
            -e "LLM_TEST_SERVICE=examples/$example" -e LLM_BASE_URL=http://mock:18080/v1 \
            -e LLM_MODEL=mock -e LLM_API_KEY=fixture-key -e LLM_EXAMPLE_ALLOW_HTTP=1 \
            -e "LLM_TEST_CONFIG=$LLM_MOCK_CONFIG" \
            --entrypoint sh "$LLM_TEST_IMAGE" \
            -c 'timeout 30 ./skynet "$LLM_TEST_CONFIG" && test "$(cat /tmp/skynet-llm-result)" = PASS'
    done
fi
if [ "$MODE" != mock ]; then
    LLM_TEST_ENV=${LLM_TEST_ENV:-.local/mao-models.env}
    test -f "$LLM_TEST_ENV" || { echo 'Missing local model env file; see component README.' >&2; exit 2; }
    rm -f .local/llm-results/real.json
    REAL_STATUS=0
    docker run --rm --user 0 --env-file "$LLM_TEST_ENV" -v "$TASK_ROOT:/workspace:ro" \
        -v "$TASK_ROOT/.local/llm-results:/results" -w /skynet -e LLM_TEST_SERVICE=integration/real \
        --entrypoint sh "$LLM_TEST_IMAGE" \
        -c 'timeout 240 ./skynet /workspace/tests/config-llm && test "$(cat /tmp/skynet-llm-result)" = PASS' || REAL_STATUS=$?
    if [ -f .local/llm-results/real.json ]; then
        echo 'Real model summary: .local/llm-results/real.json'
    else
        echo 'Real model run produced no fresh report.' >&2
        if [ "$REAL_STATUS" = 0 ]; then REAL_STATUS=1; fi
    fi
    if [ "$REAL_STATUS" != 0 ]; then
        echo 'Real provider did not pass every capability; any fresh report records FAIL / INCOMPATIBLE / UNSUPPORTED.' >&2
        exit "$REAL_STATUS"
    fi
fi
echo 'PASS: Skynet LLM Docker tests'
