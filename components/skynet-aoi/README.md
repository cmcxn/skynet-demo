# Pluto AOI integration

## Source and scope

- Upstream: <https://github.com/cloudfreexiao/pluto>
- Pinned gitlink: `0fdadf37ed121cb3e8c86d8cfa08ec00f0f84738`
- Compiled files: `lualib-src/lua-aoi/lua_aoi.cpp`, `aoi.hpp`, `rect.hpp`
- License: upstream MIT, copyright (c) 2024 cloudfreexiao. The original
  `vendor/pluto/LICENSE` is retained and copied into distributable packages.
- C++17, using **this repository's** `vendor/skynet/3rd/lua` headers (Lua 5.5.1).
  Linux/macOS resolve Lua symbols from the host; MinGW links the existing
  Skynet `lua54` import library (its historical name, internally Lua 5.5.1).

Only the AOI module is built. Pluto's build system, Skynet fork, and other
libraries are not used. No upstream source or Skynet core is patched by this
component. The whole Pluto repository is a Git submodule because Git cannot
submodule just one directory. Initialize with:

```sh
./scripts/update-submodules.sh
```

Do not recursively initialize Pluto's own `skynet` submodule. To upgrade later,
explicitly check out the desired Pluto commit, rerun the tests, and commit the
new gitlink in the parent repository.

## Build and test

Docker builds install `aoi.so`, `skynet_aoi.lua`, the test suite, and the license.
The Linux runtime includes `libstdc++6`. Tests exercise the installed image
without mounting host native modules:

```sh
./scripts/test-aoi.sh docker
# Reuse an already-built image:
AOI_SKIP_BUILD=1 AOI_TEST_IMAGE=skynet-aoi-demo:dev ./scripts/test-aoi.sh docker
```

Native Linux, with the normal Skynet build prerequisites installed:

```sh
make -C vendor/skynet linux -j4
./scripts/test-aoi.sh native
```

The native test runner needs GNU `timeout`, a C++17 compiler, and a previously
built Skynet executable plus its bundled Lua interpreter. On a development
machine without jemalloc/autoconf, Skynet can instead use its supported system
allocator build (this is how this branch was tested):

```sh
make -C vendor/skynet linux -j4 MALLOC_STATICLIB= SKYNET_DEFINES=-DNOUSE_JEMALLOC
./scripts/test-aoi.sh native
```

Standalone component build:

```sh
make -C components/skynet-aoi
vendor/skynet/3rd/lua/lua components/skynet-aoi/tests/unit.lua
```

Custom paths are supported by `LUA_INC`, `PLUTO_DIR`, `OUT_DIR`, `CXX`,
`CXXFLAGS`, `SHARED`, `LDFLAGS`, and `LDLIBS` in the component Makefile.
Always rebuild against the matching Lua headers; do not use the system Lua ABI.

Windows packaging uses the existing `./scripts/build-windows.sh` flow and adds
`test-aoi.bat`. It runs the same offline suite with the packaged Lua and DLL.
The AOI DLL retains the `.so` suffix expected by Skynet. The existing dependency
scan bundles any non-system DLLs. macOS has a dynamic-lookup build rule.
**Docker, Windows/MinGW/Wine, and macOS were not executed in this branch's cloud
environment.** Linux standalone and real Skynet-service testing are separate
from those unverified platforms.

## Recommended Lua API

Use `require "skynet_aoi"`. `require "aoi"` exposes the unmodified unsafe native
binding and is retained only for internal compatibility and diagnostics.
Add `components/skynet-aoi/lualib/?.lua` to `lua_path` and
`components/skynet-aoi/luaclib/?.so` to `lua_cpath` in a source checkout. Installed
Docker and Windows packages already use their normal `lualib`/`luaclib` paths.

```lua
local aoi = require "skynet_aoi"
local space = aoi.new(0, 0, 1000, 20) -- origin x/y, square map size, tile size
space:enable_leave_event(true)       -- movement leave is OFF by default
assert(space:insert(1, 100, 100, 80, 80, 0, aoi.WATCHER))
assert(space:insert(2, 110, 100, 0, 0, 0, aoi.MARKER))
local out = {}
local n = space:update_event(out)
for i = 1, n, 3 do
    local watcher, marker, event = out[i], out[i + 1], out[i + 2]
    assert(watcher == 1 and marker == 2 and event == aoi.ENTER)
end
assert(space:update(2, 900, 900, 0, 0, 0))
assert(space:update_event(out) == 3) -- now one LEAVE triple; old tail is cleared
space:erase(2)
space:close()                       -- idempotent; native destruction is by GC
```

Methods preserve the native API shape unless noted:

- `new(x, y, map_size, tile_size)`: square 2-D integer grid. The safe entry point
  normalizes the origin to `(0, 0)` internally; no coordinates escape to callers.
- `insert(id, x, y, width, height, layer, mode) -> boolean`
- `update(id, x, y, width, height, layer) -> boolean`: mode does not change.
- `erase(id)`: missing IDs are harmless. Remaining watchers receive leave events
  when a marker is deleted, even if movement-leave generation is disabled.
  Removing a watcher does not emit its outgoing leave relationships.
- `has(id) -> boolean`
- `query(x, y, width, height, out) -> count`: point markers only, no distance sort;
  returns **0** for empty results (raw native binding returns no value).
- `update_event(out) -> flat_element_count`: triples are
  `{watcher_id, marker_id, event_id, ...}`. Divide by three for the event count.
- `fire_event(marker_id, event_id)`: sends an application event to current
  watchers, including itself when the object has combined watcher-marker mode
  (upstream semantics); a watcher-only ID is rejected before the native assertion.
- `enable_leave_event(boolean)` / `enable_debug(boolean)`
- `close() -> boolean`: drops ownership; returns false after the first close.
  Other methods on a closed space raise a Lua error. A scoped Lua `<close>`
  variable is also supported. Unclosed spaces are reclaimed by normal GC.

Modes are `WATCHER=1`, `MARKER=2`, `WATCHER_MARKER=3`; event constants are
`ENTER=1`, `LEAVE=2`. `layer` is accepted but **does not filter visibility**.
Use separate space instances for separate maps/instances; do not use layer as
map isolation. A space belongs to one Lua state/service and is not shareable
between Skynet services.

Every successful or failed native mutation (`insert`, `update`, `erase`,
`fire_event`) replaces the previous operation's event buffer. Read after each
mutation. `update_event` does **not** consume events; repeated reads return the
same event relationships. `query`, `has`, and option setters do not clear them.
Arguments rejected by the Lua wrapper never reach the native mutation and leave
its previous event buffer untouched. Output tables are replaced in place,
including stale tails. Do not rely on hash-set iteration/event order.

Rectangles include both boundaries. Width/height describe the full view size;
the integer radius on each axis is `size // 2` (an odd size rounds down).
Map coordinates include `origin` through `origin + map_size`. Insert/update
outside the map return false. Queries may be centered outside the map, and a
fully disjoint query returns zero.

## Validation and upstream limitations

The wrapper is a small integration guard, not a rewritten AOI algorithm:

- IDs must fit Lua's integer type. Coordinates, origins, layers, and custom event
  IDs must be signed 32-bit integers. Fractional numbers, NaN, infinity, and numeric strings
  are rejected; integral Lua numbers such as `1.0` are accepted.
- Map/view sizes are bounded by `0x3fffffff` to prevent native signed-arithmetic
  overflow. Map/tile sizes must be positive, evenly divisible, and contain no
  more than 1024 tiles per side. This is a safety ceiling, not a recommendation:
  large grids still allocate significant memory; no hard object/memory budget
  is provided. Map upper bounds must fit int32.
- Marker-only objects require zero width/height. They are point markers, not
  range markers. Combined watcher-marker objects may have a nonzero view.
- Original native construction with `new(0,0,100,0)` divides by zero and was
  reproduced as SIGFPE in an isolated subprocess. Invalid constructor calls
  must go through the safe entry point.
- At the pinned upstream commit, inserting two combined-mode objects at
  `(50,50)` with a `40x40` view in a `100/10` grid, then deleting one, produces
  **25 identical `(remaining_watcher, removed_marker, LEAVE)` triples**. Native
  `erase` visits all covered view tiles and notifies the same watcher repeatedly.
  The wrapper deduplicates the exact watcher/marker/event triple **within one
  read of one operation only**. Distinct relationships/event IDs and later
  operations are retained. Upstream source stays unchanged.
- Native tile optimizations use origin-relative tile rectangles; normalization
  keeps those calculations consistent for callers using nonzero origins.
- Do not call the raw userdata's `__gc` manually or pass foreign userdata into
  native methods. The wrapper keeps the raw userdata private and lets Lua GC
  destroy it once. This is input hardening, not a sandbox against Lua debug APIs
  or a guarantee that arbitrary native allocation failures become Lua errors.

## Coverage

The shared suite covers loading, create/close/GC lifecycles, watcher-first and
marker-first insertions, enter/leave toggling, movement across tiles, map/view
edges, changing view size, nonzero origins, deletion, combined-mode duplicate
leaves, consecutive mutations and repeated reads, reused output tables,
separate-space isolation, query results, layer semantics, custom events, and
invalid arguments. A deterministic 500-operation test compares visibility
changes and queries against a simple brute-force oracle. The Linux test runner
executes the suite both in the bundled Lua interpreter and in a real Skynet
service, with a fresh result file and process timeout.
