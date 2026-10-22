-- Run with the runtime Lua and its lualib/luaclib paths.
-- Standalone Lua uses the same upstream crypt implementation via client.so.
package.preload['skynet.crypt'] = assert(package.loadlib(assert(arg[1], 'pass runtime/luaclib/client.so'), 'luaopen_skynet_crypt'))
local proxy = require 'http.proxy'
local count = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    assert(ok, name .. ': ' .. tostring(err)); count = count + 1
end
local function env(values) return function(k) return values[k] end end
local function selected(url, values, override)
    return proxy.select(proxy.origin(url), override, env(values))
end
local function fails(fn)
    local ok, err = pcall(fn); assert(not ok); return tostring(err)
end
test('origin preserves authority and bare hostname', function()
    local o = proxy.origin('https://example2.test:8443')
    assert(o.host == 'example2.test' and o.port == 8443 and o.authority == 'example2.test:8443')
    assert(o.protocol == 'https' and o.connect_authority == 'example2.test:8443')
    assert(proxy.origin('[::1]:8080').host == '::1')
end)
test('reject origin injection and malformed ports', function()
    for _,s in ipairs{'https://x/evil','https://x\r\nfoo:1','https://x:65536','https://x:0','ftp://x','https://u:p@x','https://x?x','https://x:'} do
        fails(function() proxy.origin(s) end)
    end
end)
test('lowercase and CGI-safe precedence', function()
    assert(not selected('http://x', {HTTP_PROXY='http://unexpected:1'}))
    assert(selected('http://x', {http_proxy='http://lower:1',HTTP_PROXY='http://upper:2'}).host == 'lower')
    assert(selected('https://x', {https_proxy='http://lower:1',HTTPS_PROXY='http://upper:2'}).host == 'lower')
    assert(selected('https://x', {HTTPS_PROXY='http://upper:2'}).host == 'upper')
    assert(not selected('https://x', {https_proxy='',HTTPS_PROXY='http://upper:2',ALL_PROXY='http://all:3'}))
    assert(selected('http://x', {ALL_PROXY='http://all:3'}).host == 'all')
    assert(not selected('https://x', {https_proxy='http://proxy:1'}, false))
end)
test('NO_PROXY DNS boundary and port', function()
    for _,h in ipairs{'example.test','sub.example.test','EXAMPLE.TEST.'} do
        assert(not selected('https://'..h, {https_proxy='http://p:1',NO_PROXY='.example.test'}))
    end
    for _,h in ipairs{'notexample.test','example.test.evil'} do
        assert(selected('https://'..h, {https_proxy='http://p:1',NO_PROXY='example.test'}))
    end
    assert(not selected('https://x:8443', {https_proxy='http://p:1',no_proxy=' x:8443 , y '}))
    assert(selected('https://x:443', {https_proxy='http://p:1',no_proxy='x:8443'}))
    assert(selected('https://x', {https_proxy='http://p:1',no_proxy='',NO_PROXY='*'}))
end)
test('NO_PROXY IPv4 CIDR and IPv6', function()
    assert(not selected('http://10.2.3.4', {http_proxy='http://p:1',no_proxy='10.0.0.0/8'}))
    assert(selected('http://110.2.3.4', {http_proxy='http://p:1',no_proxy='10.0.0.0/8'}))
    assert(not selected('http://[::1]:8080', {http_proxy='http://p:1',no_proxy='[::1]:8080'}))
    assert(not selected('http://[::1]', {http_proxy='http://p:1',no_proxy='::1'}))
end)
test('userinfo decoded only for Basic and never in errors', function()
    local p = selected('https://x', {https_proxy='http://user:p%40ss%3Aword@proxy:3128/'})
    assert(p.host == 'proxy' and p.port == 3128)
    assert(p.authorization == 'Basic dXNlcjpwQHNzOndvcmQ=')
    for _,s in ipairs{'https://user:secret@proxy','http://user:secret@proxy/path','http://user:%GG@proxy','socks5://user:secret@proxy'} do
        local err = fails(function() selected('https://x', {https_proxy=s}) end)
        assert(not err:find('secret',1,true) and not err:find('user:',1,true))
    end
end)
print('PASS: '..count..' proxy configuration unit groups')
