package.path = 'components/skynet-llm/lualib/?.lua;' .. package.path
local ok, sse = pcall(require, 'skynet_llm.transport.sse')
assert(ok, 'SSE parser must be implemented: ' .. tostring(sse))

local checks = 0
local function check(name, fn)
    fn()
    checks = checks + 1
    print('PASS SSE: ' .. name)
end
local function append(to, from)
    assert(from)
    for _, event in ipairs(from) do to[#to + 1] = event end
end

-- Removing byte buffering or tying event boundaries to read boundaries breaks this.
check('arbitrary split preserves UTF-8, multiline data, CRLF and SSE fields', function()
    local wire = '\239\187\191: heartbeat\r\nid: 42\r\nevent: delta\r\ndata: 你好\r\ndata: world\r\n\r\ndata: [DONE]\n\n'
    for split = 0, #wire do
        local p, events = sse.new(), {}
        append(events, p:feed(wire:sub(1, split)))
        append(events, p:feed(wire:sub(split + 1)))
        append(events, p:finish())
        assert(#events == 2)
        assert(events[1].data == '你好\nworld' and events[1].event == 'delta' and events[1].id == '42')
        assert(events[2].data == '[DONE]' and events[2].event == 'message' and events[2].id == '42')
    end
end)
check('one byte reads and bare CR delimiters preserve events', function()
    local p, events = sse.new(), {}
    local wire = 'data: 好\r\rdata:\n\n'
    for i = 1, #wire do append(events, p:feed(wire:sub(i,i))) end
    append(events, p:finish())
    assert(#events == 2 and events[1].data == '好' and events[2].data == '')
end)
check('comments and unknown fields do not create events', function()
    local p = sse.new()
    assert(#assert(p:feed(': comment\nunknown: value\n\ndata: x\n\n')) == 1)
    assert(#assert(p:finish()) == 0)
end)
check('EOF cannot dispatch an event without its final blank line', function()
    for _, wire in ipairs({'data: x', 'data: x\n', 'data: x\r\n'}) do
        local p = sse.new()
        assert(p:feed(wire))
        local events, err = p:finish()
        assert(not events and err.code == 'stream_interrupted')
    end
end)
check('event and unfinished line caps apply before EOF', function()
    for _, wire in ipairs({'data: 123456789', ': 123456789012345', 'data: x\ndata: y\n'}) do
        local p = sse.new {max_event_bytes = 12}
        local events, err = p:feed(wire)
        assert(not events and err.code == 'invalid_response')
    end
end)
check('malformed UTF-8 is a protocol error', function()
    local events, err = sse.new():feed('data: \255\n\n')
    assert(not events and err.code == 'invalid_response')
end)
print('SSE unit checks: ' .. checks)
