local flatten
do
  local __flatten
  __flatten = function(t, buffer)
    local _exp_0 = type(t)
    if "string" == _exp_0 then
      buffer[#buffer + 1] = t
    elseif "number" == _exp_0 then
      buffer[#buffer + 1] = tostring(t)
    elseif "table" == _exp_0 then
      for _index_0 = 1, #t do
        local thing = t[_index_0]
        __flatten(thing, buffer)
      end
    end
  end
  flatten = function(t)
    local buffer = { }
    __flatten(t, buffer)
    return table.concat(buffer)
  end
end

-- Pure Lua base64 (no luasocket "mime" dependency, no ngx). Skynet has no
-- built-in base64, so this replaces the original mime.b64/mime.unb64 path.
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function encode_base64(data)
  local out = {}
  local len = #data
  local i = 1
  while i <= len do
    local b1, b2, b3 = data:byte(i, i + 2)
    b2 = b2 or 0
    b3 = b3 or 0
    local n = (b1 << 16) | (b2 << 8) | b3

    local c1 = (n >> 18) & 0x3F
    local c2 = (n >> 12) & 0x3F
    local c3 = (n >> 6) & 0x3F
    local c4 = n & 0x3F

    local rem = len - i + 1
    out[#out + 1] = B64_CHARS:sub(c1 + 1, c1 + 1)
    out[#out + 1] = B64_CHARS:sub(c2 + 1, c2 + 1)
    out[#out + 1] = rem >= 2 and B64_CHARS:sub(c3 + 1, c3 + 1) or "="
    out[#out + 1] = rem >= 3 and B64_CHARS:sub(c4 + 1, c4 + 1) or "="

    i = i + 3
  end
  return table.concat(out)
end

local B64_REVERSE = {}
for i = 1, #B64_CHARS do
  B64_REVERSE[B64_CHARS:byte(i)] = i - 1
end

local function decode_base64(data)
  data = data:gsub("[^%w%+%/%=]", "")
  local out = {}
  local i = 1
  local len = #data
  while i <= len do
    local c1 = data:byte(i)
    local c2 = data:byte(i + 1)
    local c3 = data:byte(i + 2)
    local c4 = data:byte(i + 3)

    local v1 = B64_REVERSE[c1] or 0
    local v2 = B64_REVERSE[c2] or 0
    local v3 = (c3 and B64_REVERSE[c3]) or 0
    local v4 = (c4 and B64_REVERSE[c4]) or 0

    local n = (v1 << 18) | (v2 << 12) | (v3 << 6) | v4

    out[#out + 1] = string.char((n >> 16) & 0xFF)
    if c3 and data:sub(i + 2, i + 2) ~= "=" then
      out[#out + 1] = string.char((n >> 8) & 0xFF)
    end
    if c4 and data:sub(i + 3, i + 3) ~= "=" then
      out[#out + 1] = string.char(n & 0xFF)
    end

    i = i + 4
  end
  return table.concat(out)
end

return {
  flatten = flatten,
  encode_base64 = encode_base64,
  decode_base64 = decode_base64
}
