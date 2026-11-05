-- Wire-level regression tests using the real driver and an in-memory socket.
-- No Skynet runtime, native module or PostgreSQL server is needed.
local input, writes, closed = '', {}, 0
package.preload.skynet = function() return {now=function() return 0 end, timeout=function() end} end
package.preload['skynet.socket'] = function() return {
  read=function(fd,n) assert(#input>=n, 'mock input exhausted');local s=input:sub(1,n);input=input:sub(n+1);return s end,
  write=function(fd,data) writes[#writes+1]=data;return true end,
  invalid=function() return false end,close=function() closed=closed+1 end,
} end
package.preload['skynet.socketdriver'] = function() return {} end
package.preload['skynet.dns'] = function() return {} end
package.preload.skynet_postgres_native = function() return {} end
local pgmoon=require 'pgmoon'
local function frame(t,s) return t..string.pack('>I4',#s+4)..s end
local function ready(status) return frame('Z',status or 'I') end
local function response(tag,status) return frame('C',tag..'\0')..ready(status) end
local function error_response(code,message) return frame('E','SERROR\0C'..code..'\0M'..message..'\0\0')..ready() end
local function connection()
  input,writes,closed='',{},0
  local p=pgmoon.new{ssl=false,timeout=5000}
  p._connected=true;p.sock.fd=1
  return p
end
local count=0
local function test(name,fn) fn();count=count+1;print('PASS '..name) end
local function packet(t)
  local stream=table.concat(writes)
  local i=1
  while i<=#stream do
    local n=string.unpack('>I4',stream,i+1)
    if stream:sub(i,i)==t then return stream:sub(i+5,i+n) end
    i=i+n+1
  end
  error('missing packet '..t)
end
test('raw BEGIN is accepted and releases the per-query operation guard',function()
  local p=connection();input=response('BEGIN','T');assert(p:query('BEGIN'))
  assert(p.sock.fd==1 and not p.sock.operation and closed==0)
  assert(packet('Q')=='BEGIN\0')
end)
test('server error containing read timeout does not close connection',function()
  local p=connection();input=error_response('P0001','application read timeout diagnostic')
  local rows,err=p:query('DO $$BEGIN RAISE EXCEPTION; END$$')
  assert(rows==nil and err:find('read timeout',1,true))
  assert(p.sock.fd==1 and closed==0 and input=='')
  input=response('SELECT 1');assert(p:query('SELECT 1'))
end)
test('trailing nil stays in extended protocol parameter arity',function()
  local p=connection();input=response('SELECT 1');assert(p:query('SELECT $1,$2,$3','x',nil,nil))
  local bind=packet('B');assert(string.unpack('>I2',bind,5)==3)
  assert(string.unpack('>i4',bind,7)==1 and bind:sub(11,11)=='x')
  assert(string.unpack('>i4',bind,12)==-1 and string.unpack('>i4',bind,16)==-1)
end)
test('original NULL sentinel encodes protocol NULL',function()
  local p=connection();input=response('SELECT 1');assert(p:query('SELECT $1',pgmoon.Postgres.NULL))
  local bind=packet('B');assert(string.unpack('>I2',bind,5)==1 and string.unpack('>i4',bind,7)==-1)
end)
test('copied NULL sentinel is rejected before writing to the socket',function()
  local p=connection();local rows,err=p:query('SELECT $1',{'NULL'})
  assert(rows==nil and err:find('does not implement pgmoon_serialize',1,true))
  assert(#writes==0 and p.sock.fd==1 and closed==0)
end)
test('definitive COMMIT constraint error is not mislabeled unknown',function()
  local p=connection();input=error_response('23503','insert or update violates foreign key constraint')
  local rows,err=p:query('COMMIT')
  assert(rows==nil and err:find('foreign key constraint',1,true))
  assert(not err:find('unknown',1,true) and p.sock.fd==1 and closed==0)
end)
test('overlapping operation rejects second caller before wire write',function()
  local p=connection();p.sock.operation={deadline=100}
  local rows,err=p:query('SELECT 1')
  assert(rows==nil and err:find('busy',1,true) and #writes==0)
end)
print(('PASS all %d repository protocol-mock checks; no live PostgreSQL used'):format(count))
