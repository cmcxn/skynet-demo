-- Safe project entry point; vendor/pluto remains an unmodified, pinned submodule.
local native = require "aoi"
local M = {WATCHER = 1, MARKER = 2, WATCHER_MARKER = 3, ENTER = 1, LEAVE = 2}
local states = setmetatable({}, {__mode = "k"})
local methods = {}
local MAX_SIZE, INT_MIN, INT_MAX = 0x3fffffff, -0x80000000, 0x7fffffff

local function integer(v, name, lo, hi)
    assert(type(v) == "number" and math.tointeger(v), name .. " must be an integer")
    v = math.tointeger(v)
    assert((not lo or v >= lo) and (not hi or v <= hi), name .. " is out of range")
    return v
end
local function state(self)
    return assert(states[self], "AOI space is closed or invalid")
end
local function position(s, x, y)
    return integer(x, "x", INT_MIN, INT_MAX) - s.x,
        integer(y, "y", INT_MIN, INT_MAX) - s.y
end
local function view(w, h, mode)
    w, h = integer(w, "view width", 0, MAX_SIZE), integer(h, "view height", 0, MAX_SIZE)
    assert(mode ~= M.MARKER or (w == 0 and h == 0), "point markers require a zero-size view")
    return w, h
end
local function output(t)
    assert(type(t) == "table", "output must be a table")
    for k in pairs(t) do t[k] = nil end
    return t
end
local function in_bounds(s, x, y)
    return x >= 0 and y >= 0 and x <= s.size and y <= s.size
end

function M.new(x, y, size, tile)
    x, y = integer(x, "origin x", INT_MIN, INT_MAX), integer(y, "origin y", INT_MIN, INT_MAX)
    size, tile = integer(size, "map size", 1, MAX_SIZE), integer(tile, "tile size", 1, MAX_SIZE)
    assert(size % tile == 0, "map size must be divisible by tile size")
    assert(size // tile <= 1024, "AOI grid exceeds 1024 tiles per side")
    assert(x + size <= INT_MAX and y + size <= INT_MAX, "map bounds exceed int32")
    local self = setmetatable({}, {__index = methods, __close = methods.close})
    -- Upstream's tile-rectangle optimizations assume an origin of (0, 0).
    states[self] = {raw = native.new(0, 0, size, tile), x = x, y = y, size = size, modes = {}}
    return self
end
function methods:close()
    local existed = states[self] ~= nil
    states[self] = nil -- The native userdata's __gc owns destruction, exactly once.
    return existed
end
function methods:insert(id, x, y, w, h, layer, mode)
    local s = state(self)
    id = integer(id, "id")
    x, y = position(s, x, y)
    mode = integer(mode, "mode", 1, 3)
    w, h = view(w, h, mode)
    layer = integer(layer, "layer", INT_MIN, INT_MAX)
    if not in_bounds(s, x, y) then x, y = -1, -1 end
    local inserted = s.raw:insert(id, x, y, w, h, layer, mode)
    if inserted then s.modes[id] = mode end
    return inserted
end
function methods:update(id, x, y, w, h, layer)
    local s = state(self)
    id = integer(id, "id")
    x, y = position(s, x, y)
    w, h = view(w, h, s.modes[id])
    layer = integer(layer, "layer", INT_MIN, INT_MAX)
    if not in_bounds(s, x, y) then x, y = -1, -1 end
    return s.raw:update(id, x, y, w, h, layer)
end
function methods:erase(id)
    local s = state(self)
    id = integer(id, "id")
    s.raw:erase(id)
    s.modes[id] = nil
end
function methods:has(id)
    return state(self).raw:has(integer(id, "id"))
end
function methods:fire_event(id, event)
    local s = state(self)
    id, event = integer(id, "id"), integer(event, "event", INT_MIN, INT_MAX)
    assert(s.modes[id] ~= M.WATCHER, "fire_event requires a marker")
    s.raw:fire_event(id, event)
end
function methods:query(x, y, w, h, out)
    local s = state(self)
    x, y = position(s, x, y)
    w, h = view(w, h)
    output(out)
    -- Avoid upstream clamping an entirely disjoint query onto a map-edge point.
    if x + w // 2 < 0 or x - w // 2 > s.size or y + h // 2 < 0 or y - h // 2 > s.size then
        return 0
    end
    return s.raw:query(x, y, w, h, out) or 0
end
function methods:update_event(out)
    local s = state(self)
    output(out)
    local raw_events, seen, n = {}, {}, 0
    local raw_n = s.raw:update_event(raw_events)
    for i = 1, raw_n, 3 do
        local watcher, marker, event = raw_events[i], raw_events[i + 1], raw_events[i + 2]
        local key = watcher .. ":" .. marker .. ":" .. event
        -- Upstream erase can emit the same relation once per covered tile.
        -- Deduplicate this read only; later operations and repeated reads are intact.
        if not seen[key] then
            seen[key] = true
            out[n + 1], out[n + 2], out[n + 3] = watcher, marker, event
            n = n + 3
        end
    end
    return n -- Flat element count, not number of events.
end
function methods:enable_leave_event(value)
    assert(type(value) == "boolean", "enabled must be a boolean")
    state(self).raw:enable_leave_event(value)
end
function methods:enable_debug(value)
    assert(type(value) == "boolean", "enabled must be a boolean")
    state(self).raw:enable_debug(value)
end
return M
