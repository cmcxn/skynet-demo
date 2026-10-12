-- SSE framing is independent of TCP reads and HTTP chunks. JSON belongs to
-- the protocol layer. feed/finish return an event list, or nil, error.
local M = {}
local Parser = {}
Parser.__index = Parser

local function fail(self, code, message)
    self.error = {code = code, stage = 'protocol', message = message, retryable = false}
    return nil, self.error
end

local function line(self, value, events)
    self.event_bytes = self.event_bytes + #value + 1
    if self.event_bytes > self.max_event_bytes then
        return fail(self, 'invalid_response', 'SSE event exceeds byte limit')
    end
    if value == '' then
        if #self.data > 0 then
            local data = table.concat(self.data, '\n')
            if not utf8.len(data) then
                return fail(self, 'invalid_response', 'SSE data is not valid UTF-8')
            end
            events[#events + 1] = {event = self.event or 'message', data = data, id = self.id}
        end
        self.data, self.event, self.event_bytes, self.fields = {}, nil, 0, false
    elseif value:sub(1,1) ~= ':' then
        self.fields = true
        local name, data = value:match('^([^:]*):(.*)$')
        if not name then name, data = value, '' end
        if data:sub(1,1) == ' ' then data = data:sub(2) end
        if name == 'data' then
            self.data[#self.data + 1] = data
        elseif name == 'event' then
            self.event = data ~= '' and data or nil
        elseif name == 'id' and not data:find('\0', 1, true) then
            self.id = data
        end
    end
    return true
end

local function consume(self, bytes, events)
    local pos = 1
    if self.after_cr then
        if bytes:sub(1,1) == '\n' then pos = 2 end
        if #bytes > 0 then self.after_cr = false end
    end
    while pos <= #bytes do
        local at = bytes:find('[\r\n]', pos)
        local tail = at and at - 1 or #bytes
        local length = tail - pos + 1
        if self.event_bytes + #self.pending + length > self.max_event_bytes then
            return fail(self, 'invalid_response', 'SSE line exceeds byte limit')
        end
        self.pending = self.pending .. bytes:sub(pos, tail)
        if not at then break end
        local ok, err = line(self, self.pending, events)
        if not ok then return nil, err end
        self.pending = ''
        pos = at + 1
        if bytes:sub(at,at) == '\r' then
            if pos > #bytes then self.after_cr = true
            elseif bytes:sub(pos,pos) == '\n' then pos = pos + 1 end
        end
    end
    return true
end

function Parser:feed(bytes)
    if self.error then return nil, self.error end
    if self.finished then return fail(self, 'invalid_response', 'SSE parser is finished') end
    assert(type(bytes) == 'string', 'SSE input must be a string')
    local events = {}
    if self.prefix then
        local need = 3 - #self.prefix
        self.prefix = self.prefix .. bytes:sub(1, need)
        bytes = bytes:sub(need + 1)
        if #self.prefix < 3 then return events end
        local prefix = self.prefix
        self.prefix = nil
        if prefix ~= '\239\187\191' then
            local ok, err = consume(self, prefix, events)
            if not ok then return nil, err end
        end
    end
    local ok, err = consume(self, bytes, events)
    if not ok then return nil, err end
    return events
end

function Parser:finish()
    if self.error then return nil, self.error end
    if self.finished then return {} end
    local events = {}
    if self.prefix then
        local prefix = self.prefix
        self.prefix = nil
        local ok, err = consume(self, prefix, events)
        if not ok then return nil, err end
    end
    self.finished = true
    if self.pending ~= '' or self.fields or #self.data > 0 then
        return fail(self, 'stream_interrupted', 'SSE ended before the final event boundary')
    end
    return events
end

function M.new(options)
    options = options or {}
    local limit = options.max_event_bytes or 1024 * 1024
    assert(type(limit) == 'number' and limit > 0 and limit < math.huge and limit % 1 == 0,
        'max_event_bytes must be a finite positive integer')
    return setmetatable({max_event_bytes = limit, pending = '', prefix = '', data = {}, event_bytes = 0}, Parser)
end

return M
