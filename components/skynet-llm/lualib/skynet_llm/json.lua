-- A service-local codec: send encoded JSON across Skynet RPC boundaries.
local M = {}
local array_mt, object_mt, null_mt = {}, {}, {}
local MAX_DEPTH = 128
M.null = setmetatable({}, null_mt)

function M.array(t)
    t = t or {}
    assert(type(t) == "table" and t ~= M.null, "array requires a table")
    return setmetatable(t, array_mt)
end

function M.object(t)
    t = t or {}
    assert(type(t) == "table" and t ~= M.null, "object requires a table")
    return setmetatable(t, object_mt)
end

-- Also used by protocol validators; malformed mixed/sparse tables have no kind.
function M.kind(t)
    if t == M.null then return "null" end
    if type(t) ~= "table" then return type(t) end
    local mt = getmetatable(t)
    if mt == array_mt then return "array" end
    if mt == object_mt then return "object" end
    local count, max, strings = 0, 0, 0
    for k in pairs(t) do
        if type(k) == "string" then strings = strings + 1
        elseif type(k) == "number" and k >= 1 and k % 1 == 0 then
            count = count + 1; if k > max then max = k end
        else return nil end
    end
    if count > 0 then
        if strings > 0 or count ~= max then return nil end
        return "array"
    end
    return "object"
end

local escaped = {['"']='\\"', ['\\']='\\\\', ['\b']='\\b', ['\f']='\\f', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t'}
function M.encode(value, options)
    assert(options == nil or type(options) == "table", "JSON encode options must be a table")
    local limit=options and options.max_bytes
    assert(limit == nil or (type(limit) == "number" and limit > 0 and limit < math.huge and limit % 1 == 0), "max_bytes must be a positive integer")
    local seen, parts, bytes = {}, {}, 0
    local function capacity(n)
        assert(not limit or n <= limit-bytes, "JSON byte limit exceeded")
    end
    local function emit(s)
        capacity(#s); bytes=bytes+#s; parts[#parts+1]=s
    end
    local function slice(s,first,last)
        if last >= first then capacity(last-first+1); emit(s:sub(first,last)) end
    end
    local function quote(s)
        -- Reject an oversized raw string before allocating its escaped form.
        capacity(#s+2); assert(utf8.len(s), "invalid UTF-8 string")
        emit('"')
        local first=1
        while true do
            local index=s:find('[%z\1-\31\\"]',first)
            if not index then break end
            slice(s,first,index-1)
            local c=s:sub(index,index)
            emit(escaped[c] or string.format("\\u%04x",string.byte(c)))
            first=index+1
        end
        slice(s,first,#s); emit('"')
    end
    local function encode(v, depth)
        if v == M.null then emit("null"); return end
        local t = type(v)
        if t == "string" then quote(v); return end
        if t == "boolean" then emit(tostring(v)); return end
        if t == "number" then
            assert(v == v and v ~= math.huge and v ~= -math.huge, "nonfinite number")
            if math.type(v) == "integer" then emit(tostring(v)); return end
            -- Lua's display formatting drops significant double digits. Retain
            -- float syntax (including -0.0) and JSON's locale-independent dot.
            local number=string.format("%.17g",v):gsub(",", ".")
            if not number:find("[%.eE]") then number=number .. ".0" end
            emit(number); return
        end
        assert(t == "table", "unsupported JSON value: " .. t)
        assert(depth <= MAX_DEPTH, "JSON nesting limit exceeded")
        assert(not seen[v], "cyclic JSON value")
        seen[v] = true
        local kind = M.kind(v)
        assert(kind == "array" or kind == "object", "mixed or sparse JSON table")
        if kind == "array" then
            emit("[")
            local n = 0
            for k in pairs(v) do
                assert(type(k) == "number" and k >= 1 and k % 1 == 0, "invalid JSON array key")
                n = n + 1
                capacity(2*n)
            end
            for i = 1, n do
                assert(rawget(v,i) ~= nil, "sparse JSON array")
                if i > 1 then emit(",") end
                encode(v[i], depth + 1)
            end
            emit("]"); seen[v] = nil; return
        end
        emit("{")
        local keys,minimum = {},1 -- Include the closing brace.
        for k in pairs(v) do
            assert(type(k) == "string", "nonstring JSON object key")
            minimum=minimum+#k+4+(#keys > 0 and 1 or 0)
            capacity(minimum); keys[#keys+1] = k
        end
        table.sort(keys)
        for i, k in ipairs(keys) do
            if i > 1 then emit(",") end
            quote(k); emit(":"); encode(v[k], depth + 1)
        end
        emit("}"); seen[v] = nil
    end
    encode(value, 1)
    return table.concat(parts)
end

function M.decode(source)
    assert(type(source) == "string", "JSON source must be a string")
    assert(utf8.len(source), "invalid UTF-8 JSON")
    local pos, size = 1, #source
    local function fail(message) error(message .. " at byte " .. pos, 0) end
    local function ws()
        while pos <= size do
            local b = source:byte(pos)
            if b == 32 or b == 9 or b == 10 or b == 13 then pos = pos + 1 else break end
        end
    end
    local function hex4()
        local h = source:sub(pos, pos + 3)
        if #h ~= 4 or not h:match("^%x%x%x%x$") then fail("invalid Unicode escape") end
        pos = pos + 4
        return tonumber(h,16)
    end
    local escapes = {['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t'}
    local function str()
        pos = pos + 1
        local parts, start = {}, pos
        while pos <= size do
            local b = source:byte(pos)
            if b == 34 then
                parts[#parts+1] = source:sub(start,pos-1); pos = pos + 1
                return table.concat(parts)
            elseif b == 92 then
                parts[#parts+1] = source:sub(start,pos-1); pos = pos + 1
                local e = source:sub(pos,pos); pos = pos + 1
                if e == "u" then
                    local code = hex4()
                    if code >= 0xD800 and code <= 0xDBFF then
                        if source:sub(pos,pos+1) ~= "\\u" then fail("missing low surrogate") end
                        pos = pos + 2; local low = hex4()
                        if low < 0xDC00 or low > 0xDFFF then fail("invalid low surrogate") end
                        code = 0x10000 + (code-0xD800)*1024 + low-0xDC00
                    elseif code >= 0xDC00 and code <= 0xDFFF then fail("unpaired low surrogate") end
                    parts[#parts+1] = utf8.char(code)
                elseif escapes[e] then parts[#parts+1] = escapes[e]
                else fail("invalid string escape") end
                start = pos
            elseif b < 32 then fail("unescaped control character")
            else pos = pos + 1 end
        end
        fail("unterminated string")
    end
    local function number()
        local start = pos
        if source:sub(pos,pos) == "-" then pos = pos+1 end
        local digit = source:sub(pos,pos)
        if digit == "0" then pos=pos+1
        elseif digit:match("^[1-9]$") then
            repeat pos=pos+1 until not source:sub(pos,pos):match("^%d$")
        else fail("invalid number") end
        if source:sub(pos,pos) == "." then
            pos=pos+1; if not source:sub(pos,pos):match("^%d$") then fail("invalid fraction") end
            repeat pos=pos+1 until not source:sub(pos,pos):match("^%d$")
        end
        if source:sub(pos,pos):match("^[eE]$") then
            pos=pos+1
            if source:sub(pos,pos):match("^[+-]$") then pos=pos+1 end
            if not source:sub(pos,pos):match("^%d$") then fail("invalid exponent") end
            repeat pos=pos+1 until not source:sub(pos,pos):match("^%d$")
        end
        local value=tonumber(source:sub(start,pos-1))
        if not value or value ~= value or value == math.huge or value == -math.huge then fail("nonfinite number") end
        return value
    end
    local parse
    parse = function(depth)
        ws(); local c=source:sub(pos,pos)
        if c == '"' then return str() end
        if c == "{" or c == "[" then
            if depth > MAX_DEPTH then fail("JSON nesting limit exceeded") end
            local object = c == "{"; local result=object and M.object{} or M.array{}
            local close=object and "}" or "]"; pos=pos+1; ws()
            if source:sub(pos,pos)==close then pos=pos+1; return result end
            while true do
                local key
                if object then
                    if source:sub(pos,pos) ~= '"' then fail("expected object key") end
                    key=str(); ws()
                    if result[key] ~= nil then fail("duplicate object key") end
                    if source:sub(pos,pos) ~= ":" then fail("expected colon") end
                    pos=pos+1
                else key=#result+1 end
                result[key]=parse(depth+1); ws(); c=source:sub(pos,pos); pos=pos+1
                if c == close then return result end
                if c ~= "," then fail("expected comma or closing delimiter") end
                ws()
            end
        end
        for literal, value in pairs({["true"]=true,["false"]=false,["null"]=M.null}) do
            if source:sub(pos,pos+#literal-1)==literal then pos=pos+#literal; return value end
        end
        if c == "-" or c:match("^%d$") then return number() end
        fail("expected JSON value")
    end
    local value=parse(1); ws()
    if pos <= size then fail("trailing JSON content") end
    return value
end

return M
