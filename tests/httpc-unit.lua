-- Narrow socket/TLS doubles exercise actual httpc/internal lifecycle and framing.
local reads, writes, timers, connected, closed, tlsclosed, init_pre, init_host
local shutdowns = 0
local now, fail_tls, stream_bad, env = 0, false, false, {}
local original_getenv = os.getenv
os.getenv = function(k) return env[k] end
package.loaded.skynet = {now=function() return now end, timeout=function(n,fn) timers[#timers+1] = fn end}
package.loaded['skynet.dns'] = {resolve=function() error('origin DNS must not run behind proxy') end}
local socket = {}
function socket.connect(host, port) connected={host,port}; return 9 end
function socket.close(fd) assert(fd==9); closed=closed+1 end
function socket.shutdown(fd) assert(fd==9); shutdowns=shutdowns+1 end
function socket.readfunc(fd, pre)
    return function(n)
        local value = pre or table.remove(reads,1); pre=nil
        assert(value,'empty fixture socket')
        if n and #value > n then table.insert(reads,1,value:sub(n+1)); return value:sub(1,n) end
        return value
    end
end
function socket.writefunc() return function(data) writes[#writes+1]=data end end
function socket.readall() return '' end
package.loaded['http.sockethelper'] = socket
package.loaded['http.tlshelper'] = {
    newctx=function() return {} end,
    newtls=function(_,_,host) init_host=host; return {} end,
    init_requestfunc=function(_,_,pre) init_pre=pre; return function() if fail_tls then error('fixture TLS failure') end end end,
    closefunc=function() return function() tlsclosed=tlsclosed+1 end end,
    readfunc=function(fd) return socket.readfunc(fd) end, writefunc=socket.writefunc, readallfunc=function() return function() return '' end end,
}
local httpc = require 'http.httpc'
local count=0
local function reset()
    reads,writes,timers,env={},{},{},{}
    connected,init_pre,init_host=nil,nil,nil
    closed,tlsclosed,fail_tls,shutdowns=0,0,false,0
    httpc.proxy=nil; httpc.timeout=20
end
local function test(name, fn)
    reset(); local ok,err=pcall(fn); assert(ok,name..': '..tostring(err)); count=count+1
end
local function response() return 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok' end
test('absolute-form HTTP keeps origin Host',function()
    env.http_proxy='http://127.0.0.1:3128'; reads={response()}
    local code,body=httpc.get('http://origin.invalid:8080','/path?q=1')
    assert(code==200 and body=='ok'); assert(connected[1]=='127.0.0.1' and connected[2]==3128)
    assert(writes[1]:find('GET http://origin.invalid:8080/path?q=1 HTTP/1.1',1,true))
    assert(writes[1]:lower():find('host:origin.invalid:8080',1,true)); assert(closed==1)
end)
test('CONNECT preserves tail and bare origin name',function()
    env.https_proxy='http://127.0.0.1:3128'; reads={'HTTP/1.1 200 Connection established\r\n\r\nTAIL',response()}
    local code=httpc.get('https://origin.invalid:8443','/',nil,{['Proxy-Authorization']='must-not-leak'})
    assert(code==200 and init_host=='origin.invalid' and init_pre=='TAIL')
    assert(writes[1]:find('CONNECT origin.invalid:8443 HTTP/1.1',1,true))
    assert(not writes[2]:lower():find('proxy-authorization',1,true)); assert(closed==1 and tlsclosed==1)
end)
test('non2xx closes with sanitized status only',function()
    env.https_proxy='http://127.0.0.1:3128'; reads={'HTTP/1.1 407 Password-secret\r\n\r\n'}
    local ok,err=pcall(httpc.get,'https://origin.invalid','/')
    assert(not ok and tostring(err):find('407',1,true) and not tostring(err):find('Password-secret',1,true))
    assert(closed==1 and not init_host)
end)
test('TLS setup failure closes fd and TLS',function()
    httpc.proxy=false; fail_tls=true
    assert(not pcall(httpc.get,'https://origin.invalid','/'))
    assert(closed==1 and tlsclosed==1)
    for _,fn in ipairs(timers) do fn() end
    assert(closed==1,'stale timeout shut down closed socket')
end)
test('stream parser failure closes socket',function()
    httpc.proxy=false; reads={'HTTP/1.1 200 OK\r\nTransfer-Encoding: bad\r\n\r\n'}
    assert(not pcall(httpc.request_stream,'GET','http://origin.invalid','/'))
    assert(closed==1)
end)
test('stream maintains timeout until close',function()
    httpc.proxy=false; reads={response()}
    local stream=httpc.request_stream('GET','http://origin.invalid','/')
    for _,fn in ipairs(timers) do fn() end
    assert(closed==1 and shutdowns==1,'stream timeout did not release idle socket')
    stream:close(); assert(closed==1)
end)
test('direct removes Proxy-Authorization without mutating caller',function()
    httpc.proxy=false; reads={response()}; local header={['Proxy-Authorization']='secret'}
    httpc.get('http://origin.invalid','/',nil,header)
    assert(not writes[1]:lower():find('proxy-authorization',1,true))
    assert(header.Host==nil and header['Proxy-Authorization']=='secret')
end)
os.getenv=original_getenv
print('PASS: '..count..' httpc lifecycle unit groups')
