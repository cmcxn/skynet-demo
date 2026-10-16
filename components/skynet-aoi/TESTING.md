# Verification record

Date: 2026-10-16. Base: `cmcxn/skynet-demo` commit
`5e67b6b3f0aef11a6093b7e4624adda73c857b52`.

## Passed in Linux cloud execution

- Existing Skynet `64391f732e76507ea6615f312cb71be1fd7bfbdd`, Lua 5.5.1:
  `make -C vendor/skynet linux -j4 MALLOC_STATICLIB= SKYNET_DEFINES=-DNOUSE_JEMALLOC TLS_MODULE=ltls TLS_LIB=/usr/lib/x86_64-linux-gnu TLS_INC=/usr/include`.
  The system allocator was used because autoconf was unavailable. Skynet source
  and gitlink were not changed. The existing build emitted an archive-tool
  warning that its `u` modifier is ignored in deterministic mode.
- `./scripts/test-aoi.sh native`: 23 checks in the bundled Lua interpreter and
  the same 23 in a real Skynet service. Includes a deterministic 500-operation
  brute-force visibility/query comparison in each run.
- Installed-layout check: copied runtime/native modules, Lua files, and tests to
  an isolated staging directory, then ran all 23 tests with only the installed
  module paths, both standalone and in Skynet. This checks installed paths; it
  does not claim a Docker image build.
- AOI compiled with `-fsanitize=address,undefined -fno-omit-frame-pointer` and
  ran all 23 tests with `ASAN_OPTIONS=detect_leaks=0:halt_on_error=1`,
  `UBSAN_OPTIONS=halt_on_error=1`, and the AddressSanitizer runtime preloaded.
  No address/undefined-behavior reports. The release module was rebuilt after
  this check.
- Existing lua-cjson and skynet-llm native extensions compiled against the same
  Lua headers. Existing LLM protocol tests: **31 passed, 0 failed**. Existing
  SSE tests: **6 passed**.
- Existing official Demo TCP regression: handshake, write/read, and round-trip
  **3 PASS** against a real local Skynet server.
- Lua syntax check (`luac -p`), shell syntax checks (`sh -n` / `bash -n`), and
  `git diff --check` passed.
- `./scripts/update-submodules.sh` retained the original Skynet/lua-cjson pins,
  initialized Pluto at the documented SHA, and left Pluto's own Skynet
  submodule uninitialized.

The initial integration test failed with the expected missing `skynet_aoi`
module before implementation. The raw zero-tile constructor and duplicate
leave issue were reproduced separately; see README for details.

## Not verified / blocked

- Docker was not installed. `./scripts/test-aoi.sh docker` and the existing
  aggregate `./scripts/test-llm.sh mock` both stopped at `docker: not found`
  (exit 127). Full Docker LLM transport/lifecycle/mock integration was not run.
- Windows/MinGW/Wine and macOS were unavailable. Build/package integration was
  added, but compilation and runtime on those platforms are unverified.
- LeakSanitizer with `detect_leaks=1` completed the 23 functional tests but then
  failed because LeakSanitizer cannot operate under this environment's ptrace
  setup. The successful address/undefined-behavior run therefore does **not**
  establish a leak-free result.
- CodeGraph CLI/tool was unavailable: requested `codegraph sync .` and
  `codegraph status .` could not run. No index was created or altered.
- No real external-model calls or external HTTPS feature tests were run.
