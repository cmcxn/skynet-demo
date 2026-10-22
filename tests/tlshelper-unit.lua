-- Test the common helper contract used by both httpc and the existing WSS client.
local pre, input, writes = nil, nil, {}
package.loaded['http.sockethelper'] = {
 readfunc=function(_,bytes) pre=bytes; return function() local ret=pre; pre=nil; return ret or 'server-flight' end end,
 writefunc=function() return function(data) writes[#writes+1]=data end end,
}
package.loaded['ltls.c'] = {}
local helper=require'http.tlshelper'
local complete=false
local context={
 set_ext_host_name=function(_,name) assert(name=='origin.test','nil replaced established TLS identity') end,
 finished=function() return complete end,
 handshake=function(_,bytes) if bytes then input=bytes;complete=true;return 'final-flight' end;return 'client-hello' end,
}
helper.init_requestfunc(1,context,'tunnel-tail')() -- websocket calls init() without another hostname
assert(complete and input=='tunnel-tail' and writes[1]=='client-hello' and writes[2]=='final-flight')
print('PASS: TLS helper preserves established identity and CONNECT tail')
