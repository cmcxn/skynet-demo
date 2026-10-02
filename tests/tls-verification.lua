local c = require "tls"
local failures, total = 0, 0
local selected = os.getenv("TLS_TEST_FILTER")
local function test(name, run)
    if selected and not name:find(selected, 1, true) then return end
    total = total + 1
    local ok, err = pcall(run)
    if ok then
        print("PASS " .. name)
    else
        failures = failures + 1
        io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
    end
    collectgarbage("collect")
end
local function rejects(run, pattern)
    local ok, err = pcall(run)
    assert(not ok, "expected rejection")
    assert(not pattern or tostring(err):find(pattern), tostring(err))
end
local function ctx(cafile, capath)
    return c.newctx(cafile, capath)
end
local function pair(hostname, cafile, version, capath)
    local client_ctx, server_ctx = ctx(cafile, capath), ctx()
    if version then
        tls_version(client_ctx, version)
        tls_version(server_ctx, version)
    end
    server_ctx:set_cert(certdir .. "/server.crt", certdir .. "/server.key")
    return c.newtls("client", client_ctx, hostname), c.newtls("server", server_ctx)
end
local function handshake(client, server)
    local outgoing = client:handshake()
    for _ = 1, 12 do
        if outgoing and #outgoing > 0 then
            if server:finished() then
                server:read(outgoing)
                outgoing = nil
            else
                outgoing = server:handshake(outgoing)
            end
        end
        if outgoing and #outgoing > 0 then
            if client:finished() then
                client:read(outgoing)
                outgoing = nil
            else
                outgoing = client:handshake(outgoing)
            end
        end
        if client:finished() and server:finished() then
            assert(tls_info(client).pending == 0, "client final flight was not returned")
            assert(tls_info(server).pending == 0, "server final flight was not returned")
            assert(server:read(client:write("authenticated")) == "authenticated")
            client:close()
            server:close()
            return
        end
        assert(outgoing and #outgoing > 0, "handshake stalled: final flight was not returned")
    end
    error("handshake did not finish")
end

test("missing explicit CA fails", function()
    rejects(function() ctx(certdir .. "/missing.pem") end, "trust")
end)
test("malformed explicit CA fails", function()
    rejects(function() ctx(certdir .. "/bad.pem") end, "trust")
end)
test("client requires hostname", function()
    rejects(function() c.newtls("client", ctx()) end, "hostname")
end)
test("client rejects empty hostname", function()
    rejects(function() c.newtls("client", ctx(), "") end, "hostname")
end)
test("client rejects embedded NUL hostname", function()
    rejects(function() c.newtls("client", ctx(), "tls.test\0evil.test") end, "hostname")
end)
test("client enables verification", function()
    local client = c.newtls("client", ctx(), "tls.test")
    assert(tls_info(client).verify_mode == 1, "SSL_VERIFY_PEER is not enabled")
    client:close()
end)
test("server does not request client certificates", function()
    local server = c.newtls("server", ctx())
    assert(tls_info(server).verify_mode == 0)
    server:close()
end)
test("DNS uses origin SNI", function()
    local client = c.newtls("client", ctx(), "tls.test")
    assert(tls_info(client).sni == "tls.test")
    client:close()
end)
test("IPv4 does not use SNI", function()
    local client = c.newtls("client", ctx(), "127.0.0.1")
    assert(tls_info(client).sni == nil, "IP address leaked into SNI")
    client:close()
end)
test("IPv6 does not use SNI", function()
    local client = c.newtls("client", ctx(), "::1")
    assert(tls_info(client).sni == nil, "IP address leaked into SNI")
    client:close()
end)
test("explicit CA verifies DNS with TLS 1.2", function()
    handshake(pair("tls.test", certdir .. "/ca.crt", 0x0303))
end)
test("explicit CA verifies DNS with TLS 1.3", function()
    handshake(pair("tls.test", certdir .. "/ca.crt", 0x0304))
end)
test("default trust environment verifies DNS", function()
    handshake(pair("tls.test"))
end)
test("explicit CA directory verifies DNS", function()
    handshake(pair("tls.test", nil, nil, certdir .. "/ca-dir"))
end)
test("explicit CA verifies IPv4 SAN", function()
    handshake(pair("127.0.0.1", certdir .. "/ca.crt"))
end)
test("explicit CA verifies IPv6 SAN", function()
    handshake(pair("::1", certdir .. "/ca.crt"))
end)
test("wrong DNS hostname fails certificate verification", function()
    rejects(function() handshake(pair("wrong.test", certdir .. "/ca.crt")) end, "certificate verification")
end)
test("wrong IP fails certificate verification", function()
    rejects(function() handshake(pair("127.0.0.2", certdir .. "/ca.crt")) end, "certificate verification")
end)
test("wrong CA fails certificate verification", function()
    rejects(function() handshake(pair("tls.test", certdir .. "/wrong-ca.crt")) end, "certificate verification")
end)
test("DNS to IP identity update clears SNI and verifies IP", function()
    local client, server = pair("wrong.test", certdir .. "/ca.crt")
    assert(client:set_ext_host_name("127.0.0.1") == 1)
    assert(tls_info(client).sni == nil)
    handshake(client, server)
end)
test("IP to DNS identity update replaces verification target", function()
    local client, server = pair("127.0.0.2", certdir .. "/ca.crt")
    assert(client:set_ext_host_name("tls.test") == 1)
    assert(tls_info(client).sni == "tls.test")
    handshake(client, server)
end)
test("identity cannot change after handshake starts", function()
    local client = c.newtls("client", ctx(), "tls.test")
    client:handshake()
    rejects(function() client:set_ext_host_name("wrong.test") end, "handshake")
    client:close()
end)
test("invalid construction remains collectable", function()
    for _ = 1, 32 do
        rejects(function() c.newtls("client", ctx(), string.rep("a", 256)) end, "hostname")
        rejects(function() c.newtls("invalid", ctx(), "tls.test") end, "method")
    end
    collectgarbage("collect")
end)
assert(failures == 0, ("%d of %d TLS tests failed"):format(failures, total))
print(("PASS all %d TLS tests"):format(total))
