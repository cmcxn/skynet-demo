-- Test origin identity propagation and resource cleanup in the real HTTP client.
local fail, closed, tls_closed, identity, initial_identity
package.loaded.skynet = {timeout=function() end}
package.loaded['skynet.dns'] = {}
package.loaded['http.sockethelper'] = {
 connect=function() return 7 end,
 close=function(fd) assert(fd==7); closed=closed+1 end,
 shutdown=function() end,
}
package.loaded['http.internal'] = {
 request=function() return 200, 'ok', {} end,
 response=function(_, _, body) return body end,
}
package.loaded['http.tlshelper'] = {
 newctx=function() if fail=='context' then error('fixture context failed') end; return {} end,
 newtls=function(_, _, host)
  identity=host
  assert(host and host~='', 'verification identity missing')
  if fail=='session' then error('fixture session failed') end
  return {}
 end,
 init_requestfunc=function() return function(host)
  initial_identity=host
  if fail=='handshake' then error('fixture certificate verification failed') end
 end end,
 closefunc=function() return function() tls_closed=tls_closed+1 end end,
 readfunc=function() end, writefunc=function() end, readallfunc=function() end,
}
local function fresh()
 closed,tls_closed,identity,initial_identity=0,0,nil,nil
 package.loaded['http.httpc']=nil
 return require 'http.httpc'
end
for _, case in ipairs{
 {'https://api.host1:8443','api.host1'},
 {'https://127.0.0.1:8443','127.0.0.1'},
 {'https://[::1]:8443','::1'},
} do
 local http=fresh()
 assert(http.get(case[1], '/')==200)
 assert(identity==case[2] and initial_identity==case[2])
 assert(closed==1 and tls_closed==1)
 print('PASS HTTP TLS identity '..case[2])
end
for _, stage in ipairs{'context','session','handshake'} do
 local http=fresh(); fail=stage
 local ok,err=pcall(http.get,'https://api.test','/')
 assert(not ok and tostring(err):find('fixture',1,true), tostring(err))
 assert(closed==1,stage..': socket leaked')
 assert(tls_closed==(stage=='handshake' and 1 or 0),stage..': TLS session leaked')
 fail=nil
 print('PASS HTTP TLS cleanup '..stage)
end
