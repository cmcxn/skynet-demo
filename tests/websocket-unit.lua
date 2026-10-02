-- Exercise real websocket + tlshelper setup with narrow transport/TLS doubles.
local connected, tls_host, closed, tls_closed, complete, fail, close_error, request_host
local writes, failures, count = {}, 0, 0
package.loaded.skynet = {error = function() end}
package.loaded['http.httpd'] = {}
package.loaded['skynet.crypt'] = {
    randomkey = function() return '12345678' end,
    base64encode = function(s) return s end,
    base64decode = function(s) return s end,
    sha1 = function() return 'accept' end,
}
package.loaded['skynet.socket'] = {
    close = function(id) assert(id == 7); closed = closed + 1 end,
    readall = function() return '' end,
}
package.loaded['http.sockethelper'] = {
    connect = function(host, port) connected = {host, tonumber(port)}; return 7 end,
    readfunc = function() return function() return 'server-flight' end end,
    writefunc = function() return function(s) writes[#writes+1] = s end end,
}
package.loaded['http.internal'] = {
    request = function(_, _, host, _, response)
        request_host = host
        if fail == 'http' then error('fixture upgrade failure') end
        response.upgrade = 'websocket'
        response.connection = 'Upgrade'
        response['sec-websocket-accept'] = 'accept'
        return 101, ''
    end,
}
package.loaded['ltls.c'] = {
    newctx = function()
        if fail == 'newctx' then error('fixture newctx failure') end
        return {}
    end,
    newtls = function(method, _, hostname)
        assert(method == 'client')
        assert(hostname and hostname ~= '', 'client hostname is required')
        tls_host = hostname
        if fail == 'newtls' then error('fixture newtls failure') end
        return {
            set_ext_host_name = function() error('initializer must retain established identity') end,
            handshake = function(_, bytes)
                if fail == 'handshake' then error('fixture certificate verification failure') end
                if bytes then
                    assert(bytes == 'server-flight')
                    complete = true
                    return 'final-flight'
                end
                return 'client-flight'
            end,
            finished = function() return complete end,
            write = function(_, bytes) return bytes end,
            close = function()
                tls_closed = tls_closed + 1
                if close_error then error('fixture close failure') end
            end,
        }
    end,
}
local function test(name, run)
    connected, tls_host, request_host, fail = nil, nil, nil, nil
    closed, tls_closed, complete, close_error, writes = 0, 0, false, false, {}
    package.loaded['http.websocket'] = nil
    local ws = require 'http.websocket'
    count = count + 1
    local ok, err = pcall(run, ws)
    if ok then print('PASS ' .. name)
    else failures = failures + 1; io.stderr:write('FAIL ' .. name .. ': ' .. tostring(err) .. '\n') end
end
local function connects(ws, url, expected_host, expected_port)
    assert(ws.connect(url) == 7)
    assert(connected[1] == expected_host and connected[2] == expected_port)
    assert(tls_host == expected_host, 'TLS verification identity differs from origin')
    assert(request_host == url:match('^wss://([^/]+)'), 'upgrade Host must retain authority')
    assert(complete and writes[1] == 'client-flight' and writes[2] == 'final-flight')
    assert(not ws.is_close(7))
    ws.close(7)
    assert(closed == 1 and tls_closed == 1 and ws.is_close(7))
end
test('WSS IPv4 retains verification identity', function(ws)
    connects(ws, 'wss://127.0.0.1:8443/chat', '127.0.0.1', 8443)
end)
test('WSS numeric-suffix DNS retains verification identity', function(ws)
    connects(ws, 'wss://service.host1/chat', 'service.host1', 443)
end)
test('WSS bracketed IPv6 verifies bare IP', function(ws)
    connects(ws, 'wss://[::1]:8443/chat', '::1', 8443)
end)
test('WSS existing DNS initializer still works', function(ws)
    connects(ws, 'wss://service.test/chat', 'service.test', 443)
end)
for _, stage in ipairs{'newctx', 'newtls', 'handshake', 'http'} do
    test('WSS ' .. stage .. ' failure releases acquired resources', function(ws)
        fail = stage
        local ok, err = pcall(ws.connect, 'wss://service.test/chat')
        assert(not ok and tostring(err):find('fixture', 1, true), tostring(err))
        assert(closed == 1, 'socket leaked')
        assert(tls_closed == ((stage == 'handshake' or stage == 'http') and 1 or 0), 'TLS context leaked')
        assert(ws.is_close(7), 'failed connection left in pool')
    end)
end
test('WSS failed TLS cleanup preserves original error and closes socket', function(ws)
    fail, close_error = 'handshake', true
    local ok, err = pcall(ws.connect, 'wss://service.test/chat')
    assert(not ok and tostring(err):find('certificate verification', 1, true), tostring(err))
    assert(closed == 1 and tls_closed == 1)
end)
test('plain WS remains direct without TLS', function(ws)
    assert(ws.connect('ws://service.host1:8080/chat') == 7)
    assert(connected[1] == 'service.host1' and connected[2] == 8080 and tls_host == nil)
    ws.close(7)
    assert(closed == 1 and tls_closed == 0)
end)
assert(failures == 0, ('%d of %d WebSocket tests failed'):format(failures, count))
print(('PASS: %d WebSocket compatibility groups'):format(count))
