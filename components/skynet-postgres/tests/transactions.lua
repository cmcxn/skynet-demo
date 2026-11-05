-- Deterministic lifecycle faults; protocol and real-server tests complement these.
local now, trace, replies, connection, made = 0, {}, {}, nil, 0
package.preload.skynet = function() return {now=function() return now end, wait=function() error('unexpected queue wait') end,wakeup=function() end} end
package.preload['pgmoon'] = function()
  return {new=function(config)
    made=made+1
    local p={timeout=config.timeout or 30000,closed=false}
    connection=p
    function p:connect() self.closed=false;return true end
    function p:disconnect() trace[#trace+1]='DISCONNECT';self.closed=true;return true end
    function p:settimeout(ms) self.timeout=ms end
    function p:query() error('facade must always use extended protocol') end
    function p:extended_query(sql,...)
      trace[#trace+1]=sql
      local args=table.pack(...)
      local response=table.remove(replies,1)
      if response then return response(self,sql,args) end
      local tag=sql:match('^(%u+)')
      local status=(tag=='BEGIN' or (tag~='COMMIT' and tag~='ROLLBACK' and self.in_tx)) and 'T' or 'I'
      self.in_tx=status=='T'
      local meta={command_tag=tag,command_tags={tag},ready_for_query=status,send_attempted=true}
      return {},1,nil,nil,nil,nil,meta
    end
    return p
  end}
end
local dbmodule=require 'pgmoon.db'
local count=0
local function test(name,fn)
  if os.getenv('PG_TEST_FILTER') and not name:find(os.getenv('PG_TEST_FILTER'),1,true) then return end
  now,trace,replies=0,{},{}
  fn();count=count+1;print('PASS '..name)
end
local function new()
  local db=dbmodule.new{timeout=1000};assert(db:connect());return db
end
local function failure(source,tag,status)
  return function() return nil,'fault',nil,nil,nil,nil,{failure_source=source,command_tag=tag,command_tags=tag and {tag} or {},ready_for_query=status,send_attempted=true,sqlstate=source=='server' and '23503' or nil} end
end
local function normal(p,sql)
  local tag=sql:match('^(%u+)');p.in_tx=tag~='COMMIT' and tag~='ROLLBACK'
  return {},1,nil,nil,nil,nil,{command_tag=tag,command_tags={tag},ready_for_query=p.in_tx and 'T' or 'I',send_attempted=true}
end
local function saw(sql) for _,v in ipairs(trace) do if v==sql then return true end end return false end
local function setup(...) replies={normal,normal,...} end -- BEGIN + local server budgets

test('private connection and explicit successful nil and false callback values',function()
  local db=new();assert(db.pg==nil and db.sock==nil)
  local ok,value=db:transaction(function(tx) assert(tx:query('SELECT 1'));return false end)
  assert(ok==true and value==false and saw('COMMIT'))
  ok,value=db:transaction(function() return nil end);assert(ok and value==nil)
end)
test('ignored SQL error is rollback-only',function()
  local db=new();setup(failure('server',nil,'E'))
  local ok,e=db:transaction(function(tx) local r,q=tx:query('SELECT broken');assert(not r and q.sqlstate=='23503');return 'ignored' end)
  assert(ok==false and e.outcome=='not_committed' and saw('ROLLBACK') and not saw('COMMIT'))
end)
test('caught abort cannot be committed',function()
  local db=new();local ok,e=db:transaction(function(tx) assert(not pcall(tx.abort,tx,'cancel'));return true end)
  assert(ok==false and e.kind=='aborted' and saw('ROLLBACK') and not saw('COMMIT'))
end)
test('callback exception preserves original value',function()
  local db=new();local original={reason='original'}
  local ok,e=db:transaction(function() error(original) end)
  assert(ok==false and e.cause==original and e.kind=='callback' and saw('ROLLBACK'))
end)
test('same-coroutine facade bypass and nested transaction reject',function()
  local db=new();local ok,e=db:transaction(function() local r,x=db:query('SELECT 1');assert(not r and x.kind=='context') end)
  assert(not ok and e.kind=='context')
  ok,e=db:transaction(function() local yes,x=db:transaction(function() end);assert(yes==false and x.kind=='context') end)
  assert(not ok and e.kind=='context')
end)
test('expired and cross-coroutine capability cannot query',function()
  local db=new();local saved
  assert(db:transaction(function(tx) saved=tx end))
  local n=#trace;local r,e=saved:query('SELECT 1');assert(not r and e.kind=='context' and #trace==n)
  local ok,x=db:transaction(function(tx)
    local co=coroutine.create(function() local a,b=tx:query('SELECT 1');assert(not a and b.kind=='context') end)
    assert(coroutine.resume(co))
  end)
  assert(not ok and x.kind=='context')
end)
test('control entry points reject before wire including nested comments',function()
  local db=new()
  for _,sql in ipairs({'BEGIN',' COMMIT','-- x\rROLLBACK','/* outer /* inner */ end */ START TRANSACTION','CALL p()','DO $$ BEGIN END $$','PREPARE x AS SELECT 1','SET statement_timeout=0','/* unterminated'}) do
    local n=#trace;local r,e=db:query(sql);assert(not r and e.kind=='sql_policy' and #trace==n,sql)
  end
  assert(db:query("/* outer /* inner */ end */ SELECT ';COMMIT'"))
end)
test('deadline checked after callback prevents commit with bounded rollback',function()
  local db=new();local ok,e=db:transaction(function() now=11 end,{timeout=100,cleanup_timeout=50})
  assert(not ok and e.kind=='timeout' and saw('ROLLBACK') and not saw('COMMIT'))
  assert(connection.timeout==1000)
end)
test('rollback failure preserves primary and discards connection',function()
  local db=new();setup(failure('server',nil,'E'),failure('transport'))
  local ok,e=db:transaction(function(tx) tx:query('SELECT broken') end)
  assert(not ok and e.sqlstate=='23503' and e.cleanup_error and connection.closed)
end)
test('explicit server COMMIT rejection is not unknown',function()
  local db=new();setup(failure('server',nil,'I'))
  local ok,e=db:transaction(function() return true end)
  assert(not ok and e.phase=='commit' and e.outcome=='not_committed' and e.sqlstate=='23503')
end)
test('lost COMMIT response is unknown and never replayed',function()
  local db=new();setup(failure('transport'))
  local before=made;local ok,e=db:transaction(function() return true end)
  assert(not ok and e.outcome=='unknown' and connection.closed and made==before)
  local commits=0;for _,q in ipairs(trace) do if q=='COMMIT' then commits=commits+1 end end;assert(commits==1)
end)
test('COMMIT acknowledgement followed disconnect is committed',function()
  local db=new();setup(failure('transport','COMMIT'))
  local ok,value,meta=db:transaction(function() return 42 end)
  assert(ok and value==42 and meta.outcome=='committed' and meta.connection_usable==false and connection.closed)
end)
test('COMMIT returning ROLLBACK is a definite failure',function()
  local db=new();setup(function() return {},1,nil,nil,nil,nil,{command_tag='ROLLBACK',command_tags={'ROLLBACK'},ready_for_query='I',send_attempted=true} end)
  local ok,e=db:transaction(function() end);assert(not ok and e.outcome=='not_committed')
end)
test('local parameter rejection preserves usable idle connection',function()
  local db=new();replies={function() return nil,'bad parameter',nil,nil,nil,nil,{failure_source='client',send_attempted=false,connection_usable=true} end}
  local r,e=db:query('SELECT $1',{})
  assert(not r and e.kind=='client' and not connection.closed)
  assert(db:query('SELECT 1'))
end)
test('ordinary write with lost response never claims not committed',function()
  local db=new();replies={failure('transport')}
  local r,e=db:query('INSERT INTO t VALUES (1)')
  assert(not r and e.outcome=='unknown' and connection.closed)
end)
test('unprintable callback errors still rollback and release owner',function()
  local db=new();local original=setmetatable({},{__tostring=function() error('formatter failed') end})
  local called,ok,e=pcall(db.transaction,db,function() error(original) end)
  assert(called and ok==false and e.kind=='callback' and e.cause==original and saw('ROLLBACK'))
  assert(db:query('SELECT 1'))
end)
test('unusable metadata retires idle connection after late timeout',function()
  local db=new();replies={function() return nil,'timeout',nil,nil,nil,nil,{failure_source='timeout',command_tag='INSERT 0 1',ready_for_query='I',send_attempted=true,connection_usable=false} end}
  local r,e=db:query('INSERT INTO t VALUES (1)');assert(not r and e.outcome=='committed')
  assert(connection.closed);assert(db:connect())
end)
test('late failure after BEGIN and COMMIT idle responses retires connection',function()
  local late=function() return nil,'late failure',nil,nil,nil,nil,{failure_source='server',sqlstate='23503',ready_for_query='I',send_attempted=true,connection_usable=false} end
  local db=new();replies={late}
  local ok=db:transaction(function() error('must not run') end);assert(not ok and connection.closed);assert(db:connect())
  setup(late);ok=db:transaction(function() end);assert(not ok and connection.closed);assert(db:connect())
end)
test('invalid options do not start transaction',function()
  local db=new()
  for _,opts in ipairs({{timeout=0},{timeout=false},{timeout=1e100},{cleanup_timeout=2147483648},{cleanup_timeout=-1},{statement_timeout=1.5},{idle_timeout='1'}}) do
    local n=#trace;local ok,e=db:transaction(function() end,opts);assert(not ok and e.kind=='config' and #trace==n)
  end
end)
print(('PASS all %d managed transaction lifecycle groups'):format(count))
