local skynet = require 'skynet'
local host = skynet.getenv('llm_test_host') or 'mock'
local ca = skynet.getenv('llm_test_ca') or '/workspace/.local/llm-fixtures/ca.pem'

skynet.start(function()
    local checks, failed = 0, false
    local function check(name, fn)
        local ok, err = xpcall(fn, debug.traceback)
        if ok then checks = checks + 1; print('PASS transport: ' .. name)
        else failed = true; io.stderr:write('FAIL transport: ' .. name .. '\n' .. tostring(err) .. '\n') end
        io.stdout:flush()
    end
    local loaded, http = pcall(require, 'skynet_llm.transport.http')
    check('HTTP transport exists', function() assert(loaded, 'HTTP transport must be implemented: ' .. tostring(http)) end)
    if not loaded then
        local marker = io.open('/tmp/skynet-llm-result', 'w'); if marker then marker:write('FAIL\n'); marker:close() end
        require('skynet.core').command('ABORT')
        return
    end
    check('native receive-credit API is installed', function()
        local driver = require 'skynet.socketdriver'
        assert(type(driver.connect_read_limit) == 'function' and type(driver.start_read_limit) == 'function',
            'the component Skynet receive-credit patch is required')
    end)
    local function profile(tls, custom_host, port)
        return {base_url = (tls and 'https://' or 'http://') .. (custom_host or host) .. ':' .. (port or (tls and 18443 or 18080)) .. '/v1',
            auth = 'none', allow_http = true, tls = tls and {ca_file = ca} or nil}
    end
    local function options(overrides)
        local t = {deadline_tick = skynet.now() + 300, connect_timeout_ms = 1000, idle_timeout_ms = 1000}
        for k,v in pairs(overrides or {}) do t[k] = v end
        return t
    end
    check('environment DNS override resolves without a platform resolver file and rejects invalid values', function()
        local sock = require 'skynet.socket'
        local address = assert(require('skynet.dns').resolve(host))
        local octets = {}; for value in address:gmatch('%d+') do octets[#octets + 1] = tonumber(value) end
        local resolver
        resolver = sock.udp(function(query, from)
            local tid = string.unpack('>I2', query)
            local answer = string.pack('>I2I2I2I2I2I2', tid, 0x8180, 1, 1, 0, 0)
                .. query:sub(13) .. string.pack('>I2I2I2I4I2', 0xc00c, 1, 1, 60, 4)
                .. string.char(table.unpack(octets))
            sock.sendto(resolver, from, answer)
        end, '127.0.0.1', 18856)
        local previous_getenv, configured = os.getenv, '127.0.0.1:18856'
        os.getenv = function(name)
            if name == 'SKYNET_LLM_DNS_SERVER' then return configured end
            return previous_getenv(name)
        end
        local ok, failure = pcall(function()
            local p = profile(false, 'windows-dns.skynet-llm.test')
            local result, err = http.request(p, '/transport/json', '{}', options())
            assert(result and result.status == 200, err and err.message)
            for _, invalid in ipairs({'bad', '256.0.0.1', '127.0.0.1:0', '127.0.0.1:65536'}) do
                configured = invalid
                result, err = http.request(p, '/transport/json', '{}', options())
                assert(not result and err.stage == 'dns' and err.message == 'invalid DNS resolver override')
            end
        end)
        os.getenv = previous_getenv
        sock.close(resolver)
        assert(ok, failure)
    end)
    check('missing native receive credit fails closed before opening a socket', function()
        local driver = require 'skynet.socketdriver'
        for _, target in ipairs({{driver, 'connect_read_limit'}, {driver, 'start_read_limit'}, {require 'skynet.socket', 'start_read_limit'}}) do
            local original, opened = target[1][target[2]], false
            target[1][target[2]] = nil
            local r, err = http.request(profile(false), '/transport/json', '{}', options {
                on_fd = function(fd) if fd then opened = true end end,
            })
            target[1][target[2]] = original
            assert(not r and err.code == 'unsupported_capability' and not err.retryable and not err.may_have_executed)
            assert(not opened)
        end
    end)
    check('native receive credit rejects zero, excessive and wrapping values', function()
        local driver = require 'skynet.socketdriver'
        for _, credit in ipairs({0, -1, 131073, 4294967297}) do
            assert(not pcall(driver.connect_read_limit, '127.0.0.1', 18888, credit))
            assert(not pcall(driver.start_read_limit, 123, credit))
        end
        for _, flag in ipairs({1, 'true', {}}) do
            assert(not pcall(driver.start_read_limit, 123, 131072, flag))
        end
    end)
    check('yielding early socket notification cannot lose connection registration', function()
        local seen, cleared = false, false
        local r, err = http.request(profile(false), '/transport/json', '{}', options {
            on_fd = function(fd)
                if fd then seen = true; skynet.sleep(5) else cleared = true end
            end,
        })
        assert(r and r.status == 200 and seen and cleared, err and err.message)
    end)
    check('peer send and close before delayed registration cannot strand the socket', function()
        local sock = require 'skynet.socket'
        local closed, current_fd = false, nil
        local listening = sock.listen('127.0.0.1', 18887)
        sock.start(listening, function(fd)
            skynet.fork(function()
                sock.start(fd)
                sock.write(fd, 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}')
                sock.close(fd)
                closed = true
            end)
        end)
        local before = skynet.now()
        local r, err = http.request(profile(false, '127.0.0.1', 18887), '/transport/json', '{}', options {
            on_fd = function(fd)
                current_fd = fd
                if fd then
                    skynet.sleep(10)
                    assert(closed, 'peer did not close before registration')
                    for _, info in ipairs(sock.netstat()) do
                        if info.id == fd then
                            assert(info.read == 0 and info.reading == false, 'connect read DATA before its first credit')
                        end
                    end
                end
            end,
        })
        sock.close(listening)
        assert((r and r.body == '{}') or (err and (err.code == 'network_error' or err.code == 'stream_interrupted')),
            err and err.message)
        assert(current_fd == nil and skynet.now() - before < 50, 'closed connection was stranded until its deadline')
    end)
    check('content length body and early socket id are usable', function()
        local seen, cleared = false, false
        local r, err = http.request(profile(false), '/transport/json', '{}', options {on_fd = function(fd)
            if fd then seen = true else cleared = true end
        end})
        assert(r, err and err.message)
        assert(r.status == 200 and r.body:find('ok', 1, true))
        assert(seen and cleared)
    end)
    check('connection refusal is safely retryable before sending HTTP bytes', function()
        local r, err = http.request(profile(false, nil, 18999), '/transport/json', '{}', options())
        assert(not r and err.code == 'network_error' and err.stage == 'connect')
        assert(err.retryable and not err.may_have_executed)
    end)
    check('connect cancellation owns the socket before OPEN arrives', function()
        local cancelled, seen = false, false
        local r, err = http.request(profile(false), '/transport/json', '{}', options {
            cancelled = function() return cancelled end,
            on_fd = function(fd) if fd then seen = true; cancelled = true end end,
        })
        assert(seen and not r and err.code == 'cancelled' and not err.may_have_executed)
    end)
    check('DNS deadline and cancellation close their private UDP lookup', function()
        local sock = require 'skynet.socket'
        local dns_fd = sock.udp(function() end, '127.0.0.1', 18853)
        for _, cancel in ipairs({false, true}) do
            local cancelled = false
            if cancel then skynet.timeout(3, function() cancelled = true end) end
            local before = skynet.now()
            local r, err = http.request(profile(false, 'pending.skynet-llm.test'), '/transport/json', '{}', options {
                deadline_tick = before + 8, connect_timeout_ms = 500,
                dns_server = {address = '127.0.0.1', port = 18853},
                cancelled = function() return cancelled end,
            })
            assert(not r and err.code == (cancel and 'cancelled' or 'timeout'))
            assert(not err.may_have_executed and skynet.now() - before < 30)
        end
        sock.close(dns_fd)
        local r, err = http.request(profile(false), '/transport/json', '{}', options())
        assert(r and r.status == 200, err and err.message)
    end)
    check('DNS ignores forged senders, unrelated IDs/questions and unlinked answer owners', function()
        local sock = require 'skynet.socket'
        local address = assert(require('skynet.dns').resolve(host))
        local ip_bytes = {}
        for value in address:gmatch('%d+') do ip_bytes[#ip_bytes + 1] = tonumber(value) end
        local good_ip = string.char(table.unpack(ip_bytes))
        local function name(value)
            local parts = {}; for label in value:gmatch('[^.]+') do parts[#parts + 1] = string.char(#label) .. label end
            return table.concat(parts) .. '\0'
        end
        local query_name = 'intended.skynet-llm.test'
        local function record(owner, kind, data)
            return name(owner) .. string.pack('>I2I2I4I2', kind, 1, 60, #data) .. data
        end
        local function response(tid, question, records)
            return string.pack('>I2I2I2I2I2I2', tid, 0x8180, 1, #records, 0, 0) .. question .. table.concat(records)
        end
        local mode, resolver, rogue_port, rogue_ip
        rogue_port = sock.udp(function() end, '127.0.0.1', 18855)
        rogue_ip = sock.udp(function() end, '127.0.0.2', 18854)
        resolver = sock.udp(function(query, from)
            local tid = string.unpack('>I2', query)
            local question = query:sub(13)
            local poison = response(tid, question, {record(query_name, 1, '\127\0\0\1')})
            if mode == 'wrong-port' then sock.sendto(rogue_port, from, poison)
            elseif mode == 'wrong-ip' then sock.sendto(rogue_ip, from, poison)
            elseif mode == 'empty-wrong-source' then sock.sendto(rogue_port, from, '')
            elseif mode == 'malformed-other-id' then sock.sendto(resolver, from, string.pack('>I2', tid ~ 1))
            elseif mode == 'wrong-question' then
                sock.sendto(resolver, from, response(tid, name('evil.test') .. string.pack('>I2I2', 1, 1), {record('evil.test', 1, '\127\0\0\1')}))
            elseif mode == 'wrong-type' then
                sock.sendto(resolver, from, response(tid, name(query_name) .. string.pack('>I2I2', 28, 1), {record(query_name, 1, '\127\0\0\1')}))
            elseif mode == 'wrong-owner' then sock.sendto(resolver, from, response(tid, question, {record('evil.test', 1, '\127\0\0\1')}))
            elseif mode == 'cname-loop' then sock.sendto(resolver, from, response(tid, question, {record(query_name, 5, name(query_name))})) end
            skynet.timeout(3, function()
                -- Unrelated A records must not supersede the valid CNAME path.
                local answer = response(tid, question, {record('evil.test', 1, '\127\0\0\1'),
                    record(query_name, 5, name('alias.skynet-llm.test')), record('alias.skynet-llm.test', 1, good_ip)})
                sock.sendto(resolver, from, answer)
            end)
        end, '127.0.0.1', 18854)
        local passed, failure = pcall(function()
            for _, candidate in ipairs({'wrong-port', 'wrong-ip', 'empty-wrong-source', 'malformed-other-id', 'wrong-question', 'wrong-type', 'wrong-owner', 'cname-loop'}) do
                mode = candidate
                local before = skynet.now()
                local r, err = http.request(profile(false, query_name), '/transport/json', '{}', options {
                    dns_server = {address = '127.0.0.1', port = 18854},
                })
                assert(r and r.status == 200, candidate .. ': ' .. tostring(err and err.message))
                assert(skynet.now() - before >= 3, candidate .. ': forged response completed the lookup')
            end
        end)
        sock.close(resolver); sock.close(rogue_port); sock.close(rogue_ip)
        assert(passed, failure)
    end)
    local function burst_case(count, pause_every, cancel_at)
        local sock = require 'skynet.socket'
        local first = 'data: first\n\n'
        local rest = string.rep('data: ' .. string.rep('x', 128) .. '\n\n', count)
        local total = #first + #rest
        local server_done = false
        local listening = sock.listen('127.0.0.1', 18888)
        sock.start(listening, function(fd)
            skynet.fork(function()
                pcall(function()
                    sock.start(fd)
                    while assert(sock.readline(fd, '\r\n')) ~= '' do end
                    assert(sock.read(fd, 2) == '{}')
                    -- A paused read side must not suppress writable readiness:
                    -- the large response queues and then drains asynchronously.
                    sock.pause(fd)
                    assert(sock.write(fd, 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: ' .. total .. '\r\n\r\n' .. first))
                    skynet.sleep(2)
                    assert(sock.write(fd, rest))
                    skynet.sleep(40)
                end)
                sock.close(fd)
                server_done = true
            end)
        end)
        local previous_error, overflows = skynet.error, 0
        local fd, events, paused_read, paused_reading, cancelled, pause_samples, cancel_tick
        local driver = require 'skynet.socketdriver'
        local previous_push, peak_buffer = driver.push, 0
        local previous_start_limit, cpu_delayed = driver.start_read_limit, false
        if previous_start_limit then
            driver.start_read_limit = function(id, limit, register_only)
                previous_start_limit(id, limit, register_only)
                if id == fd and events and events >= 4096 and not cpu_delayed then
                    -- Delay this service after granting a read while its peer
                    -- has a large queued write. Lua cannot send a pause until
                    -- the delay ends, so only native credit can bound DATA.
                    cpu_delayed = true
                    local until_cpu = os.clock() + 0.1
                    while os.clock() < until_cpu do end
                end
            end
        end
        driver.push = function(...)
            local size = previous_push(...)
            peak_buffer = math.max(peak_buffer, size)
            return size
        end
        skynet.error = function(...)
            if tostring((...)):find('socket buffer overflow', 1, true) then overflows = overflows + 1 end
            return previous_error(...)
        end
        events = 0
        pause_samples = 0
        local function sample_pause()
            for _, info in ipairs(sock.netstat()) do
                if info.id == fd then
                    paused_read, paused_reading = info.read, info.reading
                    pause_samples = pause_samples + 1
                    assert(info.reading == false, 'socket kept reading during consumer pause')
                end
            end
        end
        local ran, failure = pcall(function()
            local r, err = http.request(profile(false, '127.0.0.1', 18888), '/transport/burst', '{}', options {
                deadline_tick = skynet.now() + 3000, on_fd = function(value) fd = value end,
                cancelled = function() return cancelled end,
            }, function(event)
                events = events + 1
                if events == 1 then
                    assert(event.data == 'first')
                    assert(not pcall(sock.read, fd, 1), 'bounded sized reads must fail locally')
                    assert(not pcall(sock.readline, fd), 'bounded line reads must fail locally')
                    assert(not pcall(sock.readall, fd), 'bounded read-all must fail locally')
                    assert(not pcall(sock.block, fd), 'bounded block must fail locally')
                    skynet.sleep(20)
                    sample_pause()
                    assert(paused_read and paused_read <= 1024 * 1024 and paused_reading == false,
                        'upstream kept reading while the consumer paused: ' .. tostring(paused_read))
                else assert(event.data == string.rep('x', 128)) end
                if pause_every and events % pause_every == 0 then
                    skynet.sleep(2)
                    sample_pause()
                    local before = paused_read
                    skynet.sleep(2)
                    sample_pause()
                    assert(paused_read == before, 'received bytes grew during sustained consumer pause')
                end
                if events == cancel_at then
                    cancel_tick = skynet.now()
                    skynet.timeout(2, function() cancelled = true end)
                    skynet.sleep(5)
                end
                return true
            end)
            if cancel_at then
                assert(not r and err.code == 'cancelled' and events == cancel_at, 'burst cancellation did not stop delivery')
                assert(skynet.now() - cancel_tick < 30 and fd == nil, 'burst cancellation did not promptly close the socket')
            else assert(r and events == count + 1, tostring(err and err.code) .. ' events=' .. events) end
            assert(overflows == 0, 'valid burst overflowed the socket buffer')
            assert(peak_buffer <= 128 * 1024, 'socket DATA buffer exceeded native receive credit')
            assert(pause_samples > 0)
            if not cancel_at then assert(cpu_delayed, 'native-credit service-delay proof did not run') end
        end)
        skynet.error = previous_error
        driver.push = previous_push
        driver.start_read_limit = previous_start_limit
        sock.close(listening)
        local wait_until = skynet.now() + 100
        while not server_done and skynet.now() < wait_until do skynet.sleep(1) end
        assert(ran, failure)
        assert(server_done, 'burst server socket was not reclaimed')
        print(string.format('Burst evidence: body=%d events=%d peak_socket_buffer=%d cancelled=%s',
            total, events, peak_buffer, tostring(not not cancel_at)))
    end
    check('17-MiB SSE burst applies upstream backpressure during a single consumer pause', function()
        burst_case(131072)
    end)
    check('near-32-MiB SSE burst tolerates sustained consumer pauses and drains paused-side writes', function()
        burst_case(246000, 4096)
    end)
    check('cancelling a sustained SSE burst closes both sockets and stops event delivery', function()
        burst_case(131072, 1024, 4096)
    end)
    check('chunked framing preserves SSE across chunk and UTF-8 boundaries', function()
        local events = {}
        local r, err = http.request(profile(false), '/transport/chunked', '{}', options(), function(event)
            events[#events + 1] = event
            skynet.sleep(1) -- callbacks may yield without running an idle timer.
            return true
        end)
        assert(r, err and err.message)
        assert(#events >= 2 and events[1].data:find('你好', 1, true))
        assert(events[#events].data == '[DONE]')
    end)
    check('consumer failure closes stream and survives callback yield', function()
        local r, err = http.request(profile(false), '/transport/chunked', '{}', options(), function()
            skynet.sleep(1)
            return nil, {code = 'consumer_too_slow', stage = 'read', message = 'test consumer stopped'}
        end)
        assert(not r and err.code == 'consumer_too_slow')
    end)
    check('terminal callback ends before malformed trailing bytes', function()
        local events = 0
        local r, err = http.request(profile(false), '/transport/terminal-tail', '{}', options(), function(event)
            events = events + 1
            assert(event.data == '[DONE]')
            return true, 'done'
        end)
        assert(r and r.status == 200 and events == 1, err and err.message)
    end)
    check('SSE requires the exact event-stream MIME type', function()
        local r, err = http.request(profile(false), '/transport/wrong-content-type', '{}', options(), function() return true end)
        assert(not r and err.code == 'invalid_response')
    end)
    check('idle deadline is suspended while a consumer callback yields', function()
        local events = 0
        local r, err = http.request(profile(false), '/transport/idle-callback', '{}', options {idle_timeout_ms = 20}, function(event)
            events = events + 1
            skynet.sleep(5)
            if event.data == '[DONE]' then return true, 'done' end
            return true
        end)
        assert(r and events >= 2, err and err.message)
    end)
    check('deadline includes time spent yielding inside a terminal callback', function()
        local r, err = http.request(profile(false), '/transport/chunked', '{}', options {
            deadline_tick = skynet.now() + 10,
        }, function()
            skynet.sleep(15)
            return true, 'done'
        end)
        assert(not r and err.code == 'timeout')
    end)
    check('framing limits and unsupported encodings fail without whole-chunk reads', function()
        for _, endpoint in ipairs({'/transport/huge-chunk', '/transport/bad-framing', '/transport/compressed', '/transport/huge-header'}) do
            local before = skynet.now()
            local r, err = http.request(profile(false), endpoint, '{}', options())
            assert(not r and err.code == 'invalid_response', endpoint .. ': ' .. tostring(err and err.code))
            assert(skynet.now() - before < 50, 'framing rejection waited for absent body bytes')
        end
    end)
    check('nonstream response bytes are capped', function()
        local p = profile(false); p.limits = {max_response_bytes = 4}
        local r, err = http.request(p, '/transport/json', '{}', options())
        assert(not r and err.code == 'invalid_response')
    end)
    check('truncated body is not accepted as success', function()
        local r, err = http.request(profile(false), '/transport/truncated', '{}', options())
        assert(not r and err.code == 'stream_interrupted' and err.may_have_executed)
    end)
    check('headers and bodies share absolute deadline', function()
        for _, endpoint in ipairs({'/transport/slow-header', '/transport/slow-body'}) do
            local before = skynet.now()
            local r, err = http.request(profile(false), endpoint, '{}', options {deadline_tick = before + 10})
            assert(not r and err.code == 'timeout')
            assert(skynet.now() - before < 50, 'deadline returned late')
        end
    end)
    check('cancellation interrupts a waiting socket read', function()
        local cancelled, fd = false
        skynet.timeout(5, function() cancelled = true end)
        local r, err = http.request(profile(false), '/transport/slow-header', '{}', options {
            cancelled = function() return cancelled end, on_fd = function(value) fd = value end,
        })
        assert(not r and err.code == 'cancelled' and fd == nil)
    end)
    check('redirect response is returned without following its Location', function()
        local r, err = http.request(profile(false), '/transport/redirect', '{}', options())
        assert(r and r.status == 302, err and err.message)
    end)
    check('plain HTTP requires explicit allow_http', function()
        local p = profile(false); p.allow_http = nil
        local r, err = http.request(p, '/transport/json', '{}', options())
        assert(not r and err.code == 'invalid_request')
    end)
    check('custom CA succeeds with original Skynet ltls loaded', function()
        local old = require 'ltls.c'; local oldctx = old.newctx(); local oldsession = old.newtls('client', oldctx, host)
        assert(#oldsession:handshake() > 0)
        local r, err = http.request(profile(true), '/transport/json', '{}', options())
        oldsession:close()
        assert(r and r.status == 200, err and err.message)
    end)
    check('TLS handshake shares the connection deadline', function()
        local before = skynet.now()
        local r, err = http.request(profile(true, nil, 18081), '/transport/json', '{}', options {connect_timeout_ms = 50})
        assert(not r and err.code == 'timeout' and err.stage == 'tls' and not err.may_have_executed)
        assert(skynet.now() - before < 30)
    end)
    check('untrusted CA and wrong hostname fail closed', function()
        local p = profile(true); p.tls = nil
        local r, err = http.request(p, '/transport/json', '{}', options())
        assert(not r and err.code == 'tls_error' and not err.may_have_executed)
        r, err = http.request(profile(true, 'wronghost'), '/transport/json', '{}', options())
        assert(not r and err.code == 'tls_error' and not err.may_have_executed)
    end)
    check('numeric IP requires an IP SAN matching the connected address', function()
        local ip = assert(require('skynet.dns').resolve(host))
        local r, err = http.request(profile(true, ip), '/transport/json', '{}', options())
        assert(not r and err.code == 'tls_error' and not err.may_have_executed)
    end)
    check('expired certificate fails closed', function()
        local r, err = http.request(profile(true, nil, 18444), '/transport/json', '{}', options())
        assert(not r and err.code == 'tls_error' and not err.may_have_executed)
    end)
    check('invalid CA path is rejected before opening a connection', function()
        local p, seen = profile(true), false
        p.tls.ca_file = '/missing/skynet-llm-test-ca.pem'
        local r, err = http.request(p, '/transport/json', '{}', options {on_fd = function(fd) if fd then seen = true end end})
        assert(not r and err.code == 'tls_error' and not seen)
    end)
    check('custom-only CA trust succeeds and requires a path', function()
        local p = profile(true); p.tls.use_default_ca = false
        local r, err = http.request(p, '/transport/json', '{}', options())
        assert(r and r.status == 200, err and err.message)
        p.tls.ca_file = nil
        r, err = http.request(p, '/transport/json', '{}', options())
        assert(not r and err.code == 'tls_error')
    end)
    check('native TLS context and session cleanup are idempotent and collectable', function()
        local native = require 'skynet_llm_tls'
        local ctx = assert(native.context {ca_file = ca})
        local session = assert(native.session(ctx, host))
        session:close(); session:close(); ctx:close(); ctx:close()
        assert(not native.context {ca_file = '/missing/skynet-llm-test-ca.pem'})
        collectgarbage('collect')
        local valid, err = require('skynet_llm.transport.tls').validate(profile(true))
        assert(valid, err and err.message)
    end)
    print('Transport integration checks: ' .. checks)
    local marker = assert(io.open('/tmp/skynet-llm-result', 'w'))
    marker:write(failed and 'FAIL\n' or 'PASS\n'); marker:close()
    require('skynet.core').command('ABORT')
end)
