-- A dependency-free suite, shared by standalone Lua and a real Skynet service.
local root = arg and arg[1] or "."
package.path = root .. "/components/skynet-aoi/lualib/?.lua;" .. package.path
package.cpath = root .. "/components/skynet-aoi/luaclib/?.so;" .. package.cpath
local ok, aoi = pcall(require, "skynet_aoi")
assert(ok, "AOI integration missing: " .. tostring(aoi))
local raw = require "aoi"
local count = 0
local function test(name, f)
    f()
    count = count + 1
    print("PASS " .. name)
end
local function rejects(f) assert(not pcall(f), "expected invalid argument to raise") end
local function space() return aoi.new(0, 0, 100, 10) end
local function events(s, expected, out)
    out = out or {}
    local n = s:update_event(out)
    assert(n == #expected * 3, "wrong event element count: " .. n)
    assert(#out == n, "stale output tail")
    local got, want = {}, {}
    for i = 1, n, 3 do got[#got + 1] = table.concat(out, ":", i, i + 2) end
    for _, e in ipairs(expected) do want[#want + 1] = table.concat(e, ":") end
    table.sort(got); table.sort(want)
    assert(table.concat(got, ",") == table.concat(want, ","),
        "event mismatch: " .. table.concat(got, ",") .. " / " .. table.concat(want, ","))
    return out
end
local function query(s, x, y, w, h, expected, out)
    out = out or {}
    local n = s:query(x, y, w, h, out)
    assert(n == #expected and #out == n, "wrong query count or stale tail")
    table.sort(out); table.sort(expected)
    assert(table.concat(out, ",") == table.concat(expected, ","), "query mismatch")
    return out
end

test("load raw binding and create/close safe spaces", function()
    assert(type(raw.new) == "function")
    local s = space()
    assert(not s:has(1))
    assert(s:close() and not s:close())
    rejects(function() s:has(1) end)
    rejects(function() s:insert(1, 1, 1, 0, 0, 0, 2) end)
end)
test("insert emits watcher-marker enter", function()
    local s = space()
    assert(s:insert(1, 50, 50, 40, 40, 0, 1))
    events(s, {})
    assert(s:insert(2, 50, 50, 0, 0, 0, 2))
    assert(s:has(1) and s:has(2))
    events(s, {{1, 2, 1}})
end)
test("inserting watcher finds an existing marker", function()
    local s = space()
    assert(s:insert(2, 50, 50, 0, 0, 0, 2))
    assert(s:insert(1, 50, 50, 40, 40, 0, 1))
    events(s, {{1, 2, 1}})
end)
test("movement leave is opt-in and can be disabled", function()
    local s = space()
    s:insert(1, 50, 50, 20, 20, 0, 1)
    s:insert(2, 50, 50, 0, 0, 0, 2)
    assert(s:update(2, 80, 80, 0, 0, 0)); events(s, {})
    assert(s:update(2, 50, 50, 0, 0, 0)); events(s, {{1, 2, 1}})
    s:enable_leave_event(true)
    assert(s:update(2, 80, 80, 0, 0, 0)); events(s, {{1, 2, 2}})
    s:update(2, 50, 50, 0, 0, 0)
    s:enable_leave_event(false)
    s:update(2, 80, 80, 0, 0, 0); events(s, {})
end)
test("cross-cell movement keeps visibility and query correct", function()
    local s = space(); s:enable_leave_event(true)
    s:insert(1, 20, 20, 40, 40, 0, 1)
    s:insert(2, 9, 20, 0, 0, 0, 2)
    s:update(2, 11, 20, 0, 0, 0); events(s, {})
    query(s, 11, 20, 0, 0, {2})
    s:update(2, 80, 80, 0, 0, 0); events(s, {{1, 2, 2}})
    query(s, 11, 20, 0, 0, {})
end)
test("watcher movement generates enter and leave", function()
    local s = space(); s:enable_leave_event(true)
    s:insert(2, 50, 50, 0, 0, 0, 2)
    s:insert(1, 10, 10, 20, 20, 0, 1)
    s:update(1, 50, 50, 20, 20, 0); events(s, {{1, 2, 1}})
    s:update(1, 90, 90, 20, 20, 0); events(s, {{1, 2, 2}})
end)
test("view expansion and contraction", function()
    local s = space(); s:enable_leave_event(true)
    s:insert(1, 50, 50, 10, 10, 0, 1)
    s:insert(2, 70, 50, 0, 0, 0, 2)
    s:update(1, 50, 50, 40, 40, 0); events(s, {{1, 2, 1}})
    s:update(1, 50, 50, 10, 10, 0); events(s, {{1, 2, 2}})
end)
test("closed map and view boundaries including upper edge", function()
    local s = space()
    s:insert(1, 0, 0, 20, 20, 0, 1)
    s:insert(2, 10, 10, 0, 0, 0, 2); events(s, {{1, 2, 1}})
    assert(s:insert(3, 100, 100, 0, 0, 0, 2))
    query(s, 100, 100, 0, 0, {3})
    assert(not s:insert(4, -1, 0, 0, 0, 0, 2))
    assert(not s:update(3, 101, 100, 0, 0, 0)); assert(s:has(3))
end)
test("nonzero origin is normalized before native calls", function()
    local s = aoi.new(-50, 200, 100, 10); s:enable_leave_event(true)
    s:insert(1, 0, 250, 10, 10, 0, 1)
    s:insert(2, 20, 250, 0, 0, 0, 2)
    s:update(1, 0, 250, 40, 40, 0); events(s, {{1, 2, 1}})
    s:update(1, 0, 250, 10, 10, 0); events(s, {{1, 2, 2}})
    query(s, 20, 250, 0, 0, {2})
end)
test("erase emits leave even when movement leave is disabled", function()
    local s = space()
    s:insert(1, 50, 50, 40, 40, 0, 1)
    s:insert(2, 50, 50, 0, 0, 0, 2)
    s:erase(2); events(s, {{1, 2, 2}}); assert(not s:has(2))
    s:erase(2); events(s, {})
end)
test("combined-mode erase deduplicates only identical triples", function()
    local s = space()
    s:insert(1, 50, 50, 40, 40, 0, 3)
    s:insert(2, 50, 50, 40, 40, 0, 3)
    events(s, {{1, 2, 1}, {2, 1, 1}})
    s:insert(3, 50, 50, 40, 40, 0, 1)
    s:erase(2); events(s, {{1, 2, 2}, {3, 2, 2}})
    query(s, 50, 50, 100, 100, {1})
end)
test("event reads repeat and reuse clears stale output", function()
    local s = space()
    s:insert(1, 50, 50, 40, 40, 0, 1)
    s:insert(2, 50, 50, 0, 0, 0, 2)
    local out = events(s, {{1, 2, 1}})
    events(s, {{1, 2, 1}}, out)
    s:update(2, 51, 51, 0, 0, 0); events(s, {}, out)
end)
test("each mutation replaces events and duplicates are rejected", function()
    local s = space()
    s:insert(1, 50, 50, 40, 40, 0, 1)
    s:insert(2, 50, 50, 0, 0, 0, 2)
    s:insert(3, 50, 50, 0, 0, 0, 2); events(s, {{1, 3, 1}})
    assert(not s:insert(3, 50, 50, 0, 0, 0, 2)); events(s, {})
    assert(not s:update(99, 50, 50, 0, 0, 0)); events(s, {})
end)
test("query contains only markers and returns zero when empty", function()
    local s = space()
    s:insert(1, 50, 50, 40, 40, 0, 1)
    s:insert(2, 50, 50, 0, 0, 0, 2)
    s:insert(3, 60, 50, 0, 0, 0, 3)
    local out = query(s, 50, 50, 20, 20, {2, 3})
    query(s, 0, 0, 0, 0, {}, out)
    query(s, -100, -100, 10, 10, {}, out)
    query(s, -1, 50, 102, 0, {2}, out)
end)
test("query does not consume events", function()
    local s = space()
    s:insert(1, 50, 50, 40, 40, 0, 1)
    s:insert(2, 50, 50, 0, 0, 0, 2)
    query(s, 50, 50, 10, 10, {2}); events(s, {{1, 2, 1}})
end)
test("separate spaces isolate identical ids", function()
    local s, other = space(), space()
    s:insert(1, 50, 50, 40, 40, 0, 1)
    other:insert(2, 50, 50, 0, 0, 0, 2)
    events(s, {}); events(other, {}); query(s, 50, 50, 100, 100, {})
    assert(not s:has(2) and not other:has(1))
end)
test("layer does not partition visibility", function()
    local s = space()
    s:insert(1, 50, 50, 40, 40, 11, 1)
    s:insert(2, 50, 50, 0, 0, 22, 2); events(s, {{1, 2, 1}})
end)
test("fire_event preserves custom event id and rejects watcher-only ids", function()
    local s = space()
    s:insert(1, 50, 50, 40, 40, 0, 1)
    s:insert(2, 50, 50, 0, 0, 0, 2)
    s:fire_event(2, 42); events(s, {{1, 2, 42}})
    rejects(function() s:fire_event(1, 42) end)
    s:fire_event(99, 42); events(s, {})
end)
test("combined-mode fire_event includes its own watcher", function()
    local s = space()
    s:insert(1, 50, 50, 40, 40, 0, 3)
    s:insert(2, 50, 50, 40, 40, 0, 1)
    s:fire_event(1, 42); events(s, {{1, 1, 42}, {2, 1, 42}})
    s:fire_event(1, 43); events(s, {{1, 1, 43}, {2, 1, 43}})
end)
test("invalid constructors reject before entering native code", function()
    for _, args in ipairs({{0,0,100,0}, {0,0,0,10}, {0,0,-100,10},
        {0,0,100,-10}, {0,0,100,3}, {0,0,100000,1}, {0,0,2^31,10},
        {2^31-1,0,100,10}, {0,0,100,0.5}}) do
        rejects(function() aoi.new(table.unpack(args)) end)
    end
end)
test("invalid method arguments cannot reach unsafe native casts", function()
    local s = space()
    for _, x in ipairs({0.5, math.huge, 0/0, "1", true, 2^32}) do
        rejects(function() s:insert(1, x, 0, 0, 0, 0, 2) end)
    end
    rejects(function() s:insert(1, 0, 0, -1, 0, 0, 1) end)
    rejects(function() s:insert(1, 0, 0, 0, 0, 0, 4) end)
    rejects(function() s:insert(1, 0, 0, 10, 10, 0, 2) end)
    rejects(function() s:update(1, 0, 0, -1, 0, 0) end)
    rejects(function() s:query(0, 0, -1, 0, {}) end)
    rejects(function() s:update_event(nil) end)
    rejects(function() s:query(0, 0, 0, 0, nil) end)
    rejects(function() s:enable_leave_event(1) end)
    rejects(function() s:has(0.5) end)
    s:enable_debug(false)
end)
test("idempotent explicit close and userdata garbage collection", function()
    local weak = setmetatable({}, {__mode = "v"})
    for i = 1, 500 do
        local s = space()
        s:insert(i, 50, 50, 0, 0, 0, 2)
        weak[i] = s
        if i % 2 == 0 then assert(s:close()); assert(not s:close()) end
    end
    collectgarbage("collect"); collectgarbage("collect")
    assert(next(weak) == nil)
    for _ = 1, 100 do local s = raw.new(0, 0, 100, 10); s:insert(1, 0, 0, 0, 0, 0, 2) end
    collectgarbage("collect"); collectgarbage("collect")
end)
test("deterministic 500-operation differential visibility and query", function()
    local s, objects, seed = aoi.new(-32, 100, 64, 8), {}, 719
    s:enable_leave_event(true)
    local function random(n) seed = (seed * 48271) % 2147483647; return seed % n end
    local function relations()
        local r = {}
        for wid, w in pairs(objects) do
            if w.mode & 1 ~= 0 then
                for mid, m in pairs(objects) do
                    if mid ~= wid and m.mode & 2 ~= 0 and math.abs(w.x-m.x) <= w.w//2
                        and math.abs(w.y-m.y) <= w.h//2 then
                        r[wid .. ":" .. mid] = {wid, mid}
                    end
                end
            end
        end
        return r
    end
    for step = 1, 500 do
        local id, before = random(20)+1, relations()
        local removing = objects[id] and random(4) == 0
        if removing then s:erase(id); objects[id] = nil
        else
            local obj = {x=random(65)-32, y=random(65)+100, w=random(17)*2, h=random(17)*2,
                mode=objects[id] and objects[id].mode or random(3)+1}
            if obj.mode == 2 then obj.w, obj.h = 0, 0 end
            if objects[id] then assert(s:update(id, obj.x, obj.y, obj.w, obj.h, 0))
            else assert(s:insert(id, obj.x, obj.y, obj.w, obj.h, 0, obj.mode)) end
            objects[id] = obj
        end
        local after, expected = relations(), {}
        for key, pair in pairs(after) do
            if not before[key] then expected[#expected+1] = {pair[1], pair[2], 1} end
        end
        for key, pair in pairs(before) do
            if not after[key] and not (removing and pair[1] == id) then
                expected[#expected+1] = {pair[1], pair[2], 2}
            end
        end
        local good, err = pcall(events, s, expected)
        assert(good, "differential step " .. step .. ": " .. tostring(err))
        local x, y, w, h = random(65)-32, random(65)+100, random(33)*2, random(33)*2
        expected = {}
        for mid, m in pairs(objects) do
            if m.mode & 2 ~= 0 and math.abs(m.x-x) <= w//2 and math.abs(m.y-y) <= h//2 then
                expected[#expected+1] = mid
            end
        end
        query(s, x, y, w, h, expected)
    end
end)
print("PASS: " .. count .. " AOI tests")
return count
