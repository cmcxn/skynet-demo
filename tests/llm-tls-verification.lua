-- Real memory-BIO handshakes through the independently verified LLM binding.
local native, server_tls = require 'skynet_llm_tls', require 'tls'
local function handshake(host, ca, certificate)
    local ctx = assert(native.context{ca_file=ca, use_default_ca=ca == nil})
    local client = assert(native.session(ctx, host))
    local server_ctx = server_tls.newctx()
    server_ctx:set_cert(certdir .. (certificate or '/server.crt'), certdir .. '/server.key')
    local server = server_tls.newtls('server', server_ctx)
    local complete = false
    for _ = 1, 12 do
        local state, err = client:handshake()
        assert(state, err)
        local outgoing = assert(client:drain())
        if #outgoing > 0 then
            local response
            if server:finished() then server:read(outgoing)
            else response = server:handshake(outgoing) end
            if response and #response > 0 then assert(client:feed(response)) end
        end
        if state == 'ok' and server:finished() then complete=true; break end
    end
    assert(complete, 'LLM handshake stalled')
    server:close(); client:close(); ctx:close()
end
local count = 0
local function test(name, accepted, run)
    local ok, err = pcall(run)
    if accepted then assert(ok, err)
    else
        assert(not ok, name .. ': expected TLS rejection')
        assert(tostring(err):find('certificate verify failed', 1, true), tostring(err))
    end
    count=count+1
    print('PASS LLM ' .. name)
    collectgarbage('collect')
end
for _, host in ipairs{'tls.test', '127.0.0.1', '::1'} do
    test('trusted ' .. host, true, function() handshake(host, certdir .. '/ca.crt') end)
end
test('default trust', true, function() handshake('tls.test') end)
test('wrong hostname', false, function() handshake('wrong.test', certdir .. '/ca.crt') end)
test('wrong IP SAN', false, function() handshake('127.0.0.2', certdir .. '/ca.crt') end)
test('untrusted issuer', false, function() handshake('tls.test', certdir .. '/wrong-ca.crt') end)
test('expired leaf', false, function() handshake('tls.test', certdir .. '/ca.crt', '/expired.crt') end)
test('self-signed leaf', false, function() handshake('tls.test', certdir .. '/ca.crt', '/selfsigned.crt') end)
assert(not native.context{ca_file=certdir .. '/missing.pem', use_default_ca=false})
assert(not native.context{ca_file=certdir .. '/bad.pem', use_default_ca=false})
print(('PASS all %d LLM TLS handshakes and missing/malformed CA checks'):format(count))
