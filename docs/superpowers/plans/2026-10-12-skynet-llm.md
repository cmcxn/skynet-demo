# Skynet LLM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Track steps below and preserve test evidence.

**Goal:** Implement the approved Skynet-only Chat/Responses/Embeddings component and test it inside Docker, including the models configured in mao.

**Architecture:** A Lua facade uses one node manager and a private worker for each request attempt; workers exit after transport cleanup, with active attempts bounded by each budget group's concurrency limit. Protocol helpers preserve native JSON and keep tool execution in the business layer. A component-owned OpenSSL adapter, incremental HTTP/SSE transport and opt-in native read credits enforce TLS verification, bounded ingress and request deadlines.

**Tech Stack:** Skynet v1.8.0, Lua 5.4, OpenSSL 3, Docker Linux.

**Spec:** `docs/superpowers/specs/2026-10-12-skynet-llm-design.md`

## Global Constraints

- Only Skynet is supported; business owns tool execution and agent loops.
- Public timeout units are milliseconds; internal absolute deadline uses Skynet ticks.
- max_inflight=4, max_queue=64; typed JSON must preserve object/array/null across RPC.
- TLS verifies peer and hostname; apply the component's runtime patch only to the build copy, without editing the pinned Skynet submodule checkout.
- API bodies are native and local options never appear on the wire.
- Endpoint and model names come from mao configuration; the working API key was separately supplied by the user. Keep test credentials in ignored `.local/`, permissions 0600; never print, commit or COPY them into images.
- All execution tests run inside Docker. Windows/macOS native support is not claimed.

## Review Focus

- Cancellation while awaiting DNS/connect/body/consumer must free resources without touching a later job.
- A complete function call can have null text; tools are associated by call_id/tool_call_id.
- TCP chunks, HTTP chunks and SSE events have unrelated boundaries.
- Queue/retry/retained-stream budgets must remain bounded during failures.
- A compatible endpoint may lack Responses, tools, or embeddings; report actual support.

## Shared interfaces

- `json.encode(value) -> string`, `json.decode(string) -> value` raise on malformed JSON; `json.array/object/null` retain types.
- `protocol.chat.validate_response(body,data,options) -> true | nil,err`; Responses and Embeddings use the same contract. `chat/responses.new_accumulator(body)` produces an object with `push(native_event)` and `finish() -> data | nil,err`.
- `transport.http.request(profile, endpoint, body_json, options, on_event) -> {status,headers,body} | nil,err`. `on_event({event,data,id})` receives raw SSE fields and may yield; options carries `deadline_tick`, `on_fd(fd_or_nil)` and `cancelled()`.
- Manager internal RPC: reserve(profile,api,body_length,options,is_stream), submit(token,body_json), await(token), next(token), result(token), cancel(token), stats, stop. Token is opaque and owner-scoped.
- Worker run(profile,api,body_json,options,token,manager) returns encoded response and metadata or nil,error; events go through synchronous manager event(token,encoded_native,raw_sse,kind).

### Task 1: Protocol, JSON and tool helpers

**Files:** components/skynet-llm/lualib/skynet_llm/{json,tools}.lua, protocol/{chat,responses,embeddings}.lua; tests/unit/protocol.lua.

- [x] Add tests for typed JSON, complete/parallel tool continuation, response replay/state continuation, fragmented accumulators and embedding index/dimension/base64 validation.
- [x] Run the final tests using Lua inside the Docker image; historical per-test red results are not reconstructed in this record.
- [x] Implement the shared interfaces and native response helpers without Skynet dependency.
- [x] Run unit tests and report exact command/output for review (31 protocol cases pass in the final integrated run).

### Task 2: Verified TLS and incremental HTTP/SSE

**Files:** components/skynet-llm/lualib-src/skynet_llm_tls.c, Makefile, transport/{tls,http,sse}.lua; tests/unit/sse.lua; tests/integration/transport.lua.

- [x] Write TLS/SSE/framing tests and verify the final cases inside Docker; historical per-test red results are not reconstructed in this record.
- [x] Implement independently scoped OpenSSL contexts and TLS state machine; compile against the pinned Lua headers.
- [x] Implement bounded HTTP/1.1 body framing, async DNS/early socket ID cancellation, header/body deadlines and SSE callback.
- [x] Verify trusted/custom CA success and wrong-host/untrusted-CA failures, partial SSE and premature EOF against controlled local fixtures.
- [x] Independently verify the final opt-in native read-credit patch under delayed Lua consumption, near-limit streams, repeated pause/resume and cancellation; confirm ordinary socket regressions pass.

### Task 3: Facade, manager and workers

**Files:** components/skynet-llm/lualib/skynet_llm.lua, {config,errors,scheduler,retry}.lua, service/{skynet_llm,skynet_llm_worker}.lua; tests/integration/client.lua and lifecycle.lua.

- [x] Write integration tests for native requests, four concurrent jobs, queue limits, errors, cancellation, retries, stream next/result, slow consumption and worker cleanup; verify final cases inside Docker.
- [x] Implement configuration and bounded admission, queue aging, per-attempt worker ownership, total deadlines and result retention.
- [x] Implement public facade, cancel token, tools/protocol exports, statistics and bounded audit delivery.
- [x] Run Docker integration tests and verify request bodies never contain options (runtime review and final image regression complete).

### Task 4: Docker harness, examples and real model validation

**Files:** Dockerfile, .dockerignore, .gitignore, components/skynet-llm/{README.md,LICENSE,examples/*,tests/*}, scripts/test-llm.sh, tests/config-llm.

- [x] Add local Python mock HTTP/TLS model fixture and Skynet test configuration; mount source and local secrets read-only.
- [x] Build component and runtime image; execute unit + integration suites and existing TCP/JSON tests.
- [x] Select required mao endpoint/model fields and store the user-supplied working key in ignored local test config; verify Git exclusion and permissions 0600.
- [x] Test chat, stream, function tools and embeddings against configured mao models; probe Responses and explicitly report supplier incompatibilities (8 PASS, 2 INCOMPATIBLE on the final runtime image).
- [x] Re-run full mock and installed-module tests, existing TCP/JSON/HTTPS examples, and real-provider smoke tests against the final patched runtime image.
- [x] Review the full diff, fix material issues, sync CodeGraph and record exact test results. Do not push.

## Execution record

- User explicitly requested immediate execution with multiple agents; proceed with independent task owners after this plan, without another confirmation round.
- Work in current checkout on `codex/skynet-llm`; no new worktree requested. Preserve existing untracked `.codegraph/` and scripts/.DS_Store.
- Task 1/2/3 can run concurrently against the contracts above; Task 4 integrates their outputs. Root owns integration and credentials only.
- Protocol, runtime and transport implementations completed independent scoped reviews with material findings resolved. Checkboxes above describe implementation and final verified coverage; they do not claim a reconstructed log of every historical red-test run.
- Reactive Lua pause plus larger buffers and a global batch cap did not reliably bound valid large streams across independent reruns. The final design uses opt-in native one-shot receive credits of at most 128 KiB: create paused, grant one DATA batch, pause before enqueue, and grant again only after Lua consumes it. Ordinary sockets keep their original mode. Missing private APIs fail with unsupported_capability.
- The six-file patch was authored during this task against pinned Skynet v1.8.0, is unofficial, and is applied only in the Docker build copy. Registration-only OPEN replay leaves native reads disabled and prevents a yielding on_fd callback from losing registration. A future Skynet update requires source review, rebasing and regression tests. Final independent stress review passed delayed Lua consumption, near-32-MiB streams, repeated pause/resume and cancellation; observed DATA batches stayed within 131072 bytes.
- Real-provider checks recorded 8 PASS and 2 INCOMPATIBLE: Responses SSE omitted output_index/content_index, and reasoning replay lacked nonempty encrypted_content. The component rejects these cases rather than discarding context or accepting malformed streams. Embeddings returned 2560 dimensions. The real test intentionally exits nonzero for those limitations; do not report all capabilities as passing.
- Final runtime image built successfully. `LLM_SKIP_BUILD=1 ./scripts/test-llm.sh mock` exited 0: 31 protocol tests, 6 SSE tests, 35 source-mode transport tests and 35 installed transport tests passed; client, lifecycle, installed client and five examples passed their result markers. Installed client/transport used UID 1000 and image-installed Lua/service/C modules. Test logs contained no Unknown session, Lua traceback or socket overflow.
- `LLM_SKIP_BUILD=1 ./scripts/test-llm.sh real` exited 1 as expected with exactly 8 PASS and 2 INCOMPATIBLE. This is a provider-capability limitation, not an all-capabilities pass.
- Existing TCP demo, lua-cjson and HTTPS regression checks passed on the final image. Installed source files, patch and license copies matched. The actual credential was absent from the 67 checked proposed source files; the local credential file remained 0600 and excluded from Git and Docker builds.
- Harness review fixes were independently verified inside an isolated Docker container: stale reports are removed before a failed run, no fresh summary is announced without a new report, nonzero Docker status is preserved, and an UNSUPPORTED response makes the aggregate and marker fail. Mock runs now own separate CA/config directories; cleanup removes only that run's generated directory.
- Final diff check and CodeGraph sync/status passed. No commit or push has been performed for this feature; mao business integration remains a separate migration.
