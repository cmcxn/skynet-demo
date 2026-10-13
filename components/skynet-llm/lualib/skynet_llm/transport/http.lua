local skynet = require 'skynet'
local socket = require 'skynet.socket'
local driver = require 'skynet.socketdriver'
local tls = require 'skynet_llm.transport.tls'
local sse = require 'skynet_llm.transport.sse'
local M = {}
local BODY_LIMIT, HEADER_LIMIT, EVENT_LIMIT = 32 * 1024 * 1024, 32 * 1024, 1024 * 1024
-- One native grant yields at most one DATA message, then pauses before enqueue.
-- The paired Lua adapter grants again only after its read-any buffer is empty.
local SOCKET_LIMIT = 128 * 1024

local function problem(code, stage, message, sent)
    return {code = code, stage = stage, message = message,
        retryable = code == 'network_error' and not sent, may_have_executed = not not sent}
end
local function ticks(ms) return math.max(1, math.ceil(ms / 10)) end
local function ipv4(host)
    local a,b,c,d = host:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
    return a and tonumber(a) <= 255 and tonumber(b) <= 255 and tonumber(c) <= 255 and tonumber(d) <= 255
end
local function url(base, endpoint, allow_http)
    if type(base) ~= 'string' or type(endpoint) ~= 'string' or endpoint:sub(1,1) ~= '/' then return nil end
    if base:find('[%s%z?#@]') or endpoint:find('[%s%z\r\n]') then return nil end
    local scheme, authority, path = base:match('^(https?)://([^/]+)(.*)$')
    if not scheme or (scheme == 'http' and not allow_http) then return nil end
    local host, port = authority:match('^([^:]+):(%d+)$')
    if not host then
        if authority:find(':', 1, true) then return nil end
        host, port = authority, scheme == 'https' and 443 or 80
    end
    port = tonumber(port)
    if not port or port < 1 or port > 65535 then return nil end
    if not host:match('^[%w_.%-]+$') or #host > 253 then return nil end
    if host:match('^[%d%.]+$') and not ipv4(host) then return nil end
    return {scheme = scheme, host = host:lower(), port = port, authority = authority, path = path:gsub('/+$', '') .. endpoint}
end
local function bounded_limit(profile, name, default)
    local value = (profile.limits or {})[name] or profile[name] or default
    if type(value) ~= 'number' or value <= 0 or value == math.huge or value % 1 ~= 0 then return nil end
    return value
end
local function new_guard(options)
    local now = skynet.now()
    local g = {alive = true, owner = coroutine.running(), stage = 'dns', sent = false,
        deadline = options.deadline_tick or now + 3000,
        connect_deadline = now + ticks(options.connect_timeout_ms or 5000),
        idle_ticks = ticks(options.idle_timeout_ms or 15000), options = options}
    function g:check(stage)
        self.stage = stage or self.stage
        if self.failure then return nil, self.failure end
        if self.options.cancelled and self.options.cancelled() then
            self.failure = problem('cancelled', 'cancel', 'request cancelled', self.sent)
        elseif skynet.now() >= self.deadline then
            self.failure = problem('timeout', self.stage, 'request deadline exceeded', self.sent)
        elseif (self.stage == 'dns' or self.stage == 'connect' or self.stage == 'tls') and skynet.now() >= self.connect_deadline then
            self.failure = problem('timeout', self.stage, 'connection deadline exceeded', self.sent)
        elseif self.idle_deadline and skynet.now() >= self.idle_deadline then
            self.failure = problem('timeout', self.stage, 'network idle timeout exceeded', self.sent)
        end
        return self.failure == nil or nil, self.failure
    end
    local function watch()
        if not g.alive then return end
        if not g:check() then
            if g.fd then driver.shutdown(g.fd) end
            if g.dns_fd then driver.close(g.dns_fd) end
            if g.waiting_dns then skynet.wakeup(g.owner) end
        else skynet.timeout(1, watch) end
    end
    skynet.timeout(1, watch)
    return g
end

-- Each lookup owns its UDP socket and closes it on completion/cancellation.
-- No fixed-timeout resolver coroutine can outlive a timed-out request.
local function hosts_lookup(host)
    local f = io.open('/etc/hosts')
    if not f then return nil end
    local found
    for line in f:lines() do
        local ip, names = line:match('^%s*([%d%.]+)%s+([^#]+)')
        if ip and ipv4(ip) then
            for name in names:gmatch('%S+') do if name:lower() == host then found = ip; break end end
        end
        if found then break end
    end
    f:close()
    return found
end
local function resolver_address(options)
    if options.dns_server then return options.dns_server.address, options.dns_server.port or 53 end
    local configured = os.getenv('SKYNET_LLM_DNS_SERVER')
    if configured and configured ~= '' then
        local address, port = configured:match('^([%d%.]+):(%d+)$')
        address, port = address or configured, tonumber(port or 53)
        if not ipv4(address) or port < 1 or port > 65535 then
            return nil, nil, 'invalid DNS resolver override'
        end
        return address, port
    end
    local f = io.open('/etc/resolv.conf')
    if not f then return nil end
    local found
    for line in f:lines() do
        local address = line:match('^%s*nameserver%s+([%d%.]+)')
        if address and ipv4(address) then found = address; break end
    end
    f:close()
    return found, 53
end
local function dns_name(bytes, pos)
    local labels, consumed, count, jumps = {}, nil, 0, 0
    while true do
        local n = bytes:byte(pos)
        if not n then error('truncated DNS name') end
        if n >= 192 then
            local second = assert(bytes:byte(pos + 1), 'truncated DNS pointer')
            local target = (n & 63) * 256 + second + 1
            -- RFC compression points to an earlier name, never into the
            -- header or forward into a record that has not been parsed.
            assert(target >= 13 and target < pos and jumps < 128, 'invalid DNS pointer')
            consumed, pos, jumps = consumed or pos + 2, target, jumps + 1
        else
            assert(n <= 63, 'invalid DNS name')
            pos, count = pos + 1, count + n + 1
            assert(count <= 255 and pos + n - 1 <= #bytes, 'invalid DNS label')
            if n == 0 then return table.concat(labels, '.'):lower(), consumed or pos end
            labels[#labels + 1] = bytes:sub(pos, pos + n - 1)
            pos = pos + n
        end
    end
end
local function dns_answer(bytes, tid, expected_name)
    -- An unrelated malformed datagram must not terminate the live lookup.
    if #bytes < 2 or string.unpack('>I2', bytes) ~= tid then return nil end
    assert(#bytes >= 12 and #bytes <= 4096, 'invalid DNS response size')
    local id, flags, questions, answers, _, _, pos = string.unpack('>I2I2I2I2I2I2', bytes)
    assert(id == tid and flags & 0xf800 == 0x8000 and flags & 0x0200 == 0, 'invalid or truncated DNS response')
    assert(questions == 1 and answers <= 128, 'invalid DNS response counts')
    local question, kind, class
    question, pos = dns_name(bytes, pos)
    kind, class, pos = string.unpack('>I2I2', bytes, pos)
    if question ~= expected_name or kind ~= 1 or class ~= 1 then return nil end
    assert(flags & 0x000f == 0, 'DNS name has no answer')
    local addresses, aliases = {}, {}
    for _ = 1, answers do
        local owner, size
        owner, pos = dns_name(bytes, pos)
        kind, class, _, size, pos = string.unpack('>I2I2I4I2', bytes, pos)
        assert(pos + size - 1 <= #bytes, 'truncated DNS record')
        if kind == 1 and class == 1 and size == 4 then
            local a,b,c,d = bytes:byte(pos, pos + 3)
            addresses[owner] = addresses[owner] or string.format('%d.%d.%d.%d', a,b,c,d)
        elseif kind == 5 and class == 1 then
            local alias, next_pos = dns_name(bytes, pos)
            assert(next_pos == pos + size, 'invalid DNS CNAME size')
            if aliases[owner] and aliases[owner] ~= alias then return nil end
            aliases[owner] = alias
        end
        pos = pos + size
    end
    local name, seen = expected_name, {}
    for _ = 1, 128 do
        if seen[name] or (addresses[name] and aliases[name]) then return nil end
        seen[name] = true
        if addresses[name] then return addresses[name] end
        if not aliases[name] then break end
        name = aliases[name]
    end
    -- Ignore unrelated answer owners and invalid alias paths; neither is a
    -- reply to this question. A legitimate later datagram may still arrive.
    if answers == 0 then error('DNS name has no IPv4 address') end
    return nil
end
local function resolve(host, guard)
    local ok, err = guard:check('dns')
    if not ok then return nil, err end
    if ipv4(host) then return host end
    local local_ip = hosts_lookup(host)
    if local_ip then return local_ip end
    local server, port, resolver_err = resolver_address(guard.options)
    if not server or not ipv4(server) then return nil, problem('network_error', 'dns', resolver_err or 'no IPv4 DNS resolver configured', false) end
    local octets = {}; for value in server:gmatch('%d+') do octets[#octets + 1] = tonumber(value) end
    server = table.concat(octets, '.')
    local labels = {}
    for label in host:gmatch('[^.]+') do
        if #label > 63 then return nil, problem('invalid_request', 'dns', 'invalid DNS name', false) end
        labels[#labels + 1] = string.char(#label) .. label
    end
    local tid = math.random(1, 65535)
    local packet = string.pack('>I2I2I2I2I2I2', tid, 0x100, 1, 0, 0, 0) .. table.concat(labels) .. '\0' .. string.pack('>I2I2', 1, 1)
    local result, dns_err, done
    local fd = socket.udp(function(bytes, from)
        if not guard.alive or done then return end
        local decoded, source, source_port = pcall(socket.udp_address, from)
        if not decoded or source ~= server or source_port ~= port then return end
        local parsed, answer = pcall(dns_answer, bytes, tid, host:gsub('%.$', ''))
        if parsed and answer == nil then return end -- unrelated transaction
        done = true
        if parsed then result = answer else dns_err = 'DNS lookup failed' end
        skynet.wakeup(guard.owner)
    end)
    guard.dns_fd = fd
    local connected = pcall(socket.udp_connect, fd, server, port)
    if connected then
        guard.waiting_dns = true
        if not socket.write(fd, packet) then dns_err = 'DNS query could not be sent' else skynet.wait(guard.owner) end
        guard.waiting_dns = false
    else dns_err = 'DNS resolver connection failed' end
    done = true
    socket.close(fd)
    guard.dns_fd = nil
    ok, err = guard:check('dns')
    if not ok then return nil, err end
    if not result then return nil, problem('network_error', 'dns', dns_err or 'DNS lookup failed', false) end
    return result
end

local function header_fields(block)
    local status_line, rest = block:match('^([^\r\n]+)\r\n(.*)$')
    if not status_line then return nil, 'invalid HTTP status line' end
    local status = status_line:match('^HTTP/1%.[01] (%d%d%d)[ \t]') or status_line:match('^HTTP/1%.[01] (%d%d%d)$')
    status = tonumber(status)
    if not status or status < 100 or status > 599 then return nil, 'invalid HTTP status' end
    local headers = {}
    for line in rest:gmatch('(.-)\r\n') do
        if line == '' then break end
        local name, value = line:match("^([!#$%%&'*+%.%^_`|~%w%-]+):[ \t]*(.-)[ \t]*$")
        if not name or value:find('[%z\1-\8\11\12\14-\31\127]') then return nil, 'invalid HTTP header' end
        name = name:lower()
        if headers[name] then
            if name == 'content-length' or name == 'transfer-encoding' then return nil, 'ambiguous HTTP framing headers' end
            headers[name] = headers[name] .. ', ' .. value
        else headers[name] = value end
    end
    return {status = status, headers = headers}
end

function M.request(profile, endpoint, body, options, on_event)
    options = options or {}
    if type(driver.connect_read_limit) ~= 'function' or type(driver.start_read_limit) ~= 'function'
        or type(socket.start_read_limit) ~= 'function' then
        return nil, problem('unsupported_capability', 'validate', 'component Skynet receive-credit patch is required', false)
    end
    local target = url(profile.base_url, endpoint, profile.allow_http)
    local max_body = bounded_limit(profile, 'max_response_bytes', BODY_LIMIT)
    local max_request = bounded_limit(profile, 'max_request_bytes', BODY_LIMIT)
    local max_header = bounded_limit(profile, 'max_header_bytes', HEADER_LIMIT)
    local max_event = bounded_limit(profile, 'max_event_bytes', EVENT_LIMIT)
    if not target or type(body) ~= 'string' or not max_body or not max_request or not max_header or not max_event or #body > max_request then
        return nil, problem('invalid_request', 'validate', 'invalid URL, body or transport byte limit', false)
    end
    local connection
    if target.scheme == 'https' then
        local err
        connection, err = tls.new(profile, target.host)
        if not connection then return nil, err end
    end
    local g = new_guard(options)
    local function cleanup()
        g.alive = false
        if connection then connection:close() end
        if g.fd then
            local fd = g.fd
            g.fd = nil
            driver.shutdown(fd)
            if socket.invalid(fd) then driver.close(fd) else socket.close(fd) end
        end
        if g.dns_fd then socket.close(g.dns_fd); g.dns_fd = nil end
        if options.on_fd then options.on_fd(nil) end
    end
    local function read_raw(stage)
        local ok, err = g:check(stage or 'read')
        if not ok then return nil, err end
        g.idle_deadline = skynet.now() + g.idle_ticks
        local bytes, tail = socket.read(g.fd)
        g.idle_deadline = nil
        -- Reading is enabled only around a network read. In particular it
        -- stays paused throughout TLS/HTTP/SSE processing and yielding
        -- consumer callbacks. socket.read resumes a paused connection only
        -- when its existing buffer is empty; buffered reads stay paused.
        if not socket.disconnected(g.fd) then socket.pause(g.fd) end
        ok, err = g:check(stage or 'read')
        if not ok then return nil, err end
        if bytes then return bytes end
        if tail and #tail > 0 then return tail end
        return nil
    end
    local function write_raw(bytes)
        local ok, err = g:check(g.stage)
        if not ok then return nil, err end
        if not socket.write(g.fd, bytes) then return nil, problem('network_error', g.stage, 'socket write failed', g.sent) end
        return true
    end
    local io_adapter = {read = read_raw, write = write_raw, check = function(stage) return g:check(stage) end}
    local function run()
        local ip, err = resolve(target.host, g)
        if not ip then return nil, err end
        local ok
        ok, err = g:check('connect')
        if not ok then return nil, err end
        -- driver.connect returns before waiting. socket.start registers the pool
        -- entry synchronously and waits for OPEN/error; deadline owns this id.
        local fd = driver.connect_read_limit(ip, target.port, SOCKET_LIMIT)
        if not fd or fd < 0 then return nil, problem('network_error', 'connect', 'socket allocation failed', false) end
        g.fd = fd
        if options.on_fd then options.on_fd(fd) end
        local started = socket.start_read_limit(fd, SOCKET_LIMIT)
        ok, err = g:check('connect')
        if not ok then return nil, err end
        if not started then return nil, problem('network_error', 'connect', 'TCP connection failed', false) end
        socket.limit(fd, SOCKET_LIMIT)
        socket.pause(fd)
        if connection then
            ok, err = connection:handshake(io_adapter)
            if not ok then return nil, err end
        end
        local headers = {'POST ' .. target.path .. ' HTTP/1.1', 'Host: ' .. target.authority,
            'Content-Type: application/json', 'Accept: ' .. (on_event and 'text/event-stream' or 'application/json'),
            'Accept-Encoding: identity', 'Connection: close', 'Content-Length: ' .. #body}
        local reserved = {host = true, ['content-length'] = true, ['transfer-encoding'] = true,
            connection = true, ['accept-encoding'] = true, authorization = true, ['proxy-authorization'] = true}
        for name,value in pairs(profile.headers or {}) do
            if type(name) ~= 'string' or type(value) ~= 'string' or reserved[name:lower()] or not name:match("^[!#$%%&'*+%.%^_`|~%w%-]+$") or value:find('[%z\r\n]') then
                return nil, problem('invalid_request', 'validate', 'invalid or reserved request header', false)
            end
            headers[#headers + 1] = name .. ': ' .. value
        end
        if profile.auth ~= 'none' then
            local key = profile.api_key
            if type(key) ~= 'string' or key == '' or key:find('[%z\r\n]') then return nil, problem('invalid_request', 'validate', 'missing or invalid authentication credential', false) end
            headers[#headers + 1] = 'Authorization: Bearer ' .. key
        end
        local head = table.concat(headers, '\r\n') .. '\r\n\r\n'
        if #head > max_header then return nil, problem('invalid_request', 'validate', 'request headers exceed byte limit', false) end
        local function write(bytes)
            if #bytes == 0 then return true end
            local checked, check_err = g:check('write')
            if not checked then return nil, check_err end
            g.sent = true -- any HTTP bytes can reach the provider.
            if connection then return connection:write(io_adapter, bytes) end
            return write_raw(bytes)
        end
        ok, err = write(head)
        if not ok then return nil, err end
        for position = 1, #body, 16384 do
            ok, err = write(body:sub(position, position + 16383))
            if not ok then return nil, err end
        end
        local buffer = ''
        local function more()
            local bytes, read_err
            if connection then bytes, read_err = connection:read(io_adapter) else bytes, read_err = read_raw('read') end
            if not bytes then return nil, read_err end
            buffer = buffer .. bytes
            return true
        end
        local header_bytes = 0
        local response
        for interim = 0, 4 do
            local at = buffer:find('\r\n\r\n', 1, true)
            while not at do
                if header_bytes + #buffer > max_header then return nil, problem('invalid_response', 'read', 'response headers exceed byte limit', g.sent) end
                ok, err = more()
                if not ok then return nil, err or problem('stream_interrupted', 'read', 'EOF before HTTP headers', g.sent) end
                at = buffer:find('\r\n\r\n', 1, true)
            end
            header_bytes = header_bytes + at + 3
            if header_bytes > max_header then return nil, problem('invalid_response', 'read', 'response headers exceed byte limit', g.sent) end
            response, err = header_fields(buffer:sub(1, at + 3))
            if not response then return nil, problem('invalid_response', 'protocol', err, g.sent) end
            buffer = buffer:sub(at + 4)
            if response.status >= 200 then break end
            if response.status == 101 or interim == 4 then return nil, problem('invalid_response', 'protocol', 'unsupported HTTP interim response', g.sent) end
        end
        local h = response.headers
        if h['content-encoding'] and h['content-encoding']:lower() ~= 'identity' then return nil, problem('invalid_response', 'protocol', 'unsupported HTTP content encoding', g.sent) end
        if h['transfer-encoding'] and (h['transfer-encoding']:lower() ~= 'chunked' or h['content-length']) then return nil, problem('invalid_response', 'protocol', 'unsupported or ambiguous HTTP body framing', g.sent) end
        local length
        if h['content-length'] then
            if not h['content-length']:match('^%d+$') then return nil, problem('invalid_response', 'protocol', 'invalid Content-Length', g.sent) end
            length = tonumber(h['content-length'])
            if not length or length > max_body then return nil, problem('invalid_response', 'read', 'response body exceeds byte limit', g.sent) end
        end
        local streaming = on_event and response.status >= 200 and response.status < 300
        local mime = (h['content-type'] or ''):lower():match('^%s*([^;]+)')
        mime = mime and mime:gsub('%s+$', '')
        if streaming and mime ~= 'text/event-stream' then return nil, problem('invalid_response', 'protocol', 'expected text/event-stream response', g.sent) end
        local parser = streaming and sse.new {max_event_bytes = max_event}
        local parts, received, stopped = {}, 0, false
        local function consume(bytes)
            received = received + #bytes
            if received > max_body then return nil, problem('invalid_response', 'read', 'response body exceeds byte limit', g.sent) end
            if not streaming then parts[#parts + 1] = bytes; return true end
            local position = 1
            while position <= #bytes do
                -- Deliver one SSE line at a time so a terminal callback stops
                -- before any trailing event or malformed bytes are inspected.
                local at = bytes:find('[\r\n]', position) or #bytes
                local events, parse_err = parser:feed(bytes:sub(position, at))
                if not events then return nil, parse_err end
                for _, event in ipairs(events) do
                    local accepted, callback_err = on_event(event)
                    if not accepted then return nil, callback_err or problem('invalid_response', 'protocol', 'stream consumer rejected event', g.sent) end
                    local checked, check_err = g:check('read')
                    if not checked then return nil, check_err end
                    if callback_err == 'done' then stopped = true; return true end
                end
                position = at + 1
            end
            return true
        end
        local function take(amount)
            while amount > 0 do
                if #buffer == 0 then
                    ok, err = more()
                    if not ok then return nil, err or problem('stream_interrupted', 'read', 'EOF before HTTP body completed', g.sent) end
                end
                local n = math.min(amount, #buffer, 16384)
                local bytes = buffer:sub(1, n)
                buffer = buffer:sub(n + 1)
                local accepted, consume_err = consume(bytes)
                if not accepted then return nil, consume_err end
                if stopped then return true end
                amount = amount - n
            end
            return true
        end
        local trailer_bytes = 0
        local function read_line()
            while true do
                local at = buffer:find('\r\n', 1, true)
                if at then
                    if at > max_header then return nil, problem('invalid_response', 'protocol', 'HTTP framing line exceeds byte limit', g.sent) end
                    local line = buffer:sub(1, at - 1)
                    buffer = buffer:sub(at + 2)
                    return line
                end
                if #buffer > max_header then return nil, problem('invalid_response', 'protocol', 'HTTP framing line exceeds byte limit', g.sent) end
                ok, err = more()
                if not ok then return nil, err or problem('stream_interrupted', 'read', 'EOF in HTTP framing', g.sent) end
            end
        end
        if response.status == 204 or response.status == 304 then
            -- These statuses have no message body, even if length is present.
        elseif h['transfer-encoding'] then
            while not stopped do
                local line, line_err = read_line()
                if not line then return nil, line_err end
                local hex, extension = line:match('^([%x]+)(.*)$')
                if not hex or #hex > 8 or (extension ~= '' and extension:sub(1,1) ~= ';') then return nil, problem('invalid_response', 'protocol', 'invalid HTTP chunk size', g.sent) end
                local amount = tonumber(hex, 16)
                if amount > max_body - received then return nil, problem('invalid_response', 'read', 'HTTP chunk exceeds remaining byte limit', g.sent) end
                if amount == 0 then
                    while true do
                        line, line_err = read_line()
                        if not line then return nil, line_err end
                        trailer_bytes = trailer_bytes + #line + 2
                        if trailer_bytes > max_header then return nil, problem('invalid_response', 'protocol', 'HTTP trailers exceed byte limit', g.sent) end
                        if line == '' then break end
                        if not line:match("^[!#$%%&'*+%.%^_`|~%w%-]+:") then return nil, problem('invalid_response', 'protocol', 'invalid HTTP trailer', g.sent) end
                    end
                    break
                end
                ok, err = take(amount)
                if not ok then return nil, err end
                if not stopped then
                    while #buffer < 2 do
                        ok, err = more()
                        if not ok then return nil, err or problem('stream_interrupted', 'read', 'EOF after HTTP chunk', g.sent) end
                    end
                    if buffer:sub(1,2) ~= '\r\n' then return nil, problem('invalid_response', 'protocol', 'invalid HTTP chunk terminator', g.sent) end
                    buffer = buffer:sub(3)
                end
            end
        elseif length then
            ok, err = take(length)
            if not ok then return nil, err end
        else
            while not stopped do
                if #buffer == 0 then
                    ok, err = more()
                    if not ok then if err then return nil, err end; break end
                end
                ok, err = take(#buffer)
                if not ok then return nil, err end
            end
        end
        if streaming and not stopped then
            local events, parse_err = parser:finish()
            if not events then return nil, parse_err end
            for _, event in ipairs(events) do
                local accepted, callback_err = on_event(event)
                if not accepted then return nil, callback_err end
            end
        end
        response.body = streaming and '' or table.concat(parts)
        return response
    end
    local ran, response, err = xpcall(run, function() return 'unexpected transport failure' end)
    cleanup()
    if not ran then return nil, problem('network_error', g.stage, response, g.sent) end
    if not response then
        err = err or problem('network_error', g.stage, 'transport failed', g.sent)
        err.may_have_executed = g.sent
    end
    return response, err
end

return M
