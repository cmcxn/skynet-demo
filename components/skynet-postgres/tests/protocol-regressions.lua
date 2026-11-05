-- Wire-level regression tests using the real driver and an in-memory socket.
-- No Skynet runtime, native module or PostgreSQL server is needed.
local input, writes, closed = '', {}, 0
local now, write_failure, expire_on_write = 0, false, false
package.preload.skynet = function() return {now=function() return now end, timeout=function() end} end
package.preload['skynet.socket'] = function() return {
  read=function(fd,n) assert(#input>=n, 'mock input exhausted');local s=input:sub(1,n);input=input:sub(n+1);return s end,
  write=function(fd,data) writes[#writes+1]=data;if expire_on_write then now=1000 end;return not write_failure end,
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
  now,write_failure,expire_on_write=0,false,false
  local p=pgmoon.new{ssl=false,timeout=5000}
  p._connected=true;p.sock.fd=1
  return p
end
local count=0
local function test(name,fn) if os.getenv('PG_TEST_FILTER') and not name:find(os.getenv('PG_TEST_FILTER'),1,true) then return end;fn();count=count+1;print('PASS '..name) end
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
test('metadata reports command tags and ready state without changing legacy slots',function()
  local p=connection();input=response('BEGIN','T')
  local rows,n,notifications,notices,fifth,sixth,m=p:query('BEGIN')
  assert(rows and n==1 and notifications==nil and notices==nil and fifth==nil and sixth==nil)
  assert(m and m.command_tag=='BEGIN' and m.command_tags[1]=='BEGIN' and m.ready_for_query=='T' and m.send_attempted)
  input=response('ROLLBACK','I');local next_meta=select(7,p:simple_query('ROLLBACK'))
  assert(next_meta~=m and #next_meta.command_tags==1 and next_meta.ready_for_query=='I')
end)
test('extended query and client rejections expose fresh metadata',function()
  local p=connection();input=response('SELECT 1')
  local m=select(7,p:extended_query('SELECT $1',1));assert(m and m.command_tag=='SELECT 1')
  m=select(7,p:query('SELECT $1',{'NULL'}))
  assert(m and m.failure_source=='client' and not m.send_attempted and #m.command_tags==0)
  p.sock.operation={deadline=100};m=select(7,p:query('SELECT 1'))
  assert(m and m.failure_source=='client' and not m.send_attempted)
  p.sock.operation=nil;p._connected=false;m=select(7,p:query('SELECT 1'))
  assert(m and m.failure_source=='client' and not m.send_attempted)
end)
test('server SQLSTATE and failed transaction state are preserved',function()
  local p=connection();input=error_response('23503','read timeout'):sub(1,-7)..ready('E')
  local rows,err,partial,n,notifications,notices,m=p:query('COMMIT')
  assert(not rows and err and n==0 and partial==nil and notifications==nil and notices==nil)
  assert(m and m.sqlstate=='23503' and m.failure_source=='server' and m.ready_for_query=='E')
end)
test('COMMIT CommandComplete survives disconnect before ReadyForQuery',function()
  local p=connection();input=frame('C','COMMIT\0')
  local rows,err,_,_,_,_,m=p:query('COMMIT')
  assert(not rows and err and closed==1)
  assert(m and m.command_tag=='COMMIT' and m.send_attempted and m.ready_for_query==nil and m.failure_source=='transport')
end)
test('COMMIT server rejection survives disconnect before ReadyForQuery',function()
  local p=connection();input=error_response('23503','deferred constraint'):sub(1,-7)
  local rows,err,_,_,_,_,m=p:query('COMMIT')
  assert(not rows and err and closed==1)
  assert(m and m.sqlstate=='23503' and m.failure_source=='server' and m.transport_failure_source=='transport')
end)
test('malformed frame size is a protocol failure',function()
  local p=connection();input='Z'..string.pack('>I4',3)
  local m=select(7,p:query('SELECT 1'))
  assert(m and m.failure_source=='protocol' and m.send_attempted and closed==1)
end)
test('all CommandComplete tags survive multi-statement results',function()
  local p=connection();input=frame('C','BEGIN\0')..frame('C','SELECT 1\0')..response('COMMIT')
  local rows,n,_,_,_,_,m=p:query('BEGIN; SELECT 1; COMMIT')
  assert(rows and n==3 and m.command_tag=='COMMIT' and #m.command_tags==3)
  assert(m.command_tags[1]=='BEGIN' and m.command_tags[2]=='SELECT 1' and m.ready_for_query=='I')
end)
test('write failure is transport with attempted-send evidence',function()
  local p=connection();write_failure=true
  local rows,err,_,_,_,_,m=p:query('COMMIT')
  assert(not rows and err and m.failure_source=='transport' and m.send_attempted and closed==1)
end)
test('operation deadline is timeout with attempted-send evidence',function()
  local p=connection();expire_on_write=true
  local rows,err,_,_,_,_,m=p:query('COMMIT')
  assert(not rows and err and m.failure_source=='timeout' and m.send_attempted and closed==1)
end)
test('invalid ReadyForQuery state is protocol failure',function()
  local p=connection();input=response('COMMIT','X')
  local rows,err,_,_,_,_,m=p:query('COMMIT')
  assert(not rows and err and m.command_tag=='COMMIT' and m.failure_source=='protocol' and not m.ready_for_query and closed==1)
end)
test('connection usability distinguishes client rejection from serializer exception',function()
  local p=connection()
  local m=select(7,p:query('SELECT $1',{'NULL'}))
  assert(m.connection_usable==true and not m.send_attempted and closed==0)
  input=response('SELECT 1');m=select(7,p:query('SELECT 1'))
  assert(m.connection_usable==true)
  local bad=setmetatable({}, {pgmoon_serialize=function() error('serializer failure') end})
  m=select(7,p:extended_query('SELECT $1',bad))
  assert(m.connection_usable==false and m.failure_source=='client' and not m.send_attempted and closed==1)
end)
test('rejection metadata reports current connection usability',function()
  local p=connection();p.sock.operation={deadline=100}
  local m=select(7,p:simple_query('SELECT 1'))
  assert(m.connection_usable==true and not m.send_attempted)
  p.sock.operation=nil;p._connected=false
  m=select(7,p:query('SELECT 1'));assert(m.connection_usable==false)
  p._connected=true;p.sock.fd=nil
  m=select(7,p:query('SELECT 1'));assert(m.connection_usable==false)
end)
test('transport loss reports unusable connection',function()
  local p=connection();input=frame('C','COMMIT\0')
  local m=select(7,p:query('COMMIT'))
  assert(m.connection_usable==false and m.command_tag=='COMMIT')
end)
test('timeout values outside scheduler range reject before any operation',function()
  for _,value in ipairs({2147483648,1e100}) do
    assert(not pcall(pgmoon.new,{ssl=false,timeout=value}),'oversized timeout accepted')
  end
end)
test('unprintable serializer exception returns a typed failure and releases guard',function()
  local p=connection()
  local bad=setmetatable({},{__tostring=function() error('formatter failed') end})
  local value=setmetatable({},{pgmoon_serialize=function() error(bad) end})
  local r=table.pack(pcall(p.query,p,'SELECT $1',value))
  assert(r[1] and r[2]==nil and type(r[3])=='string' and r[8].failure_source=='client')
  assert(not p.sock.operation and p._query_metadata==nil and not p.sock.fd)
end)
-- The facade is also exercised through the actual driver and wire decoder.
-- Concurrency itself is covered by the real Skynet integration tests.
package.preload['skynet.queue']=function() return function() return function(fn,...) return fn(...) end end end
local function managed_connection()
  local p=connection();local factory=pgmoon.new
  pgmoon.new=function() return p end
  local db=require('pgmoon.db').new{ssl=false,timeout=5000}
  pgmoon.new=factory
  p.connect=function() return true end
  assert(db:connect())
  return db,p
end
local begin_and_limits=response('BEGIN','T')..response('SELECT 1','T')
test('facade confirms actual COMMIT tag even when ReadyForQuery is lost',function()
  local db=managed_connection();input=begin_and_limits..frame('C','COMMIT\0')
  local ok,value,m=db:transaction(function() return 42 end)
  assert(ok and value==42 and m.outcome=='committed' and not m.connection_usable and closed==1)
end)
test('facade treats actual COMMIT transport loss as unknown without replay',function()
  local db=managed_connection();input=begin_and_limits
  local ok,e=db:transaction(function() return 42 end)
  assert(not ok and e.outcome=='unknown' and closed==1)
  local _,commits=table.concat(writes):gsub('COMMIT','');assert(commits==1)
end)
test('facade keeps actual COMMIT server rejection definitive after disconnect',function()
  local db=managed_connection();input=begin_and_limits..error_response('23503','deferred constraint'):sub(1,-7)
  local ok,e=db:transaction(function() end)
  assert(not ok and e.outcome=='not_committed' and e.sqlstate=='23503' and closed==1)
end)
test('custom serializers never receive the private facade connection',function()
  local db=managed_connection();local captured
  local value=setmetatable({},{pgmoon_serialize=function(_,context) captured=context;return 25,'safe' end})
  input=begin_and_limits..response('SELECT 1','T')..response('COMMIT')
  assert(db:transaction(function(tx) assert(tx:query('SELECT $1',value)) end))
  assert(captured and captured.NULL==pgmoon.Postgres.NULL)
  assert(captured.sock==nil and captured.query==nil and captured.extended_query==nil and captured.disconnect==nil,
    'serializer leaked the private connection')
end)
test('serializer cannot reenter facade disconnect during an ordinary query',function()
  local db=managed_connection();local rejection
  local value=setmetatable({},{pgmoon_serialize=function()
    local ok,e=db:disconnect();assert(not ok);rejection=e;return 25,'safe'
  end})
  input=response('SELECT 1');assert(db:query('SELECT $1',value))
  assert(rejection.kind=='context','reentrant facade disconnect was not rejected at entry')
  input=response('SELECT 1');assert(db:query('SELECT 1'))
end)
print(('PASS all %d repository protocol-mock checks; no live PostgreSQL used'):format(count))
