-- Application-owned connection: one queue for ordinary queries AND whole transactions.
-- This is a trusted-SQL API, not a sandbox. See the component README for boundaries.
local skynet = require 'skynet'
local queue = require 'skynet.queue'
local pgmoon = require 'pgmoon'
local unpack = table.unpack
local allowed = {}
for word in ('SELECT INSERT UPDATE DELETE MERGE WITH VALUES TABLE CREATE ALTER DROP TRUNCATE COMMENT EXPLAIN ANALYZE REFRESH'):gmatch('%S+') do allowed[word]=true end

-- Only the leading keyword is classified here. PostgreSQL's extended-protocol
-- Parse enforces one statement; do not split SQL with regexes or trust semicolons.
local function permitted(sql)
  if type(sql)~='string' or sql:find('\0',1,true) then return false end
  local i,n=1,#sql
  while i<=n do
    local c=sql:sub(i,i)
    if c:match('%s') then i=i+1
    elseif sql:sub(i,i+1)=='--' then
      local stop=sql:find('[\r\n]',i+2);i=stop or n+1
    elseif sql:sub(i,i+1)=='/*' then
      local depth=1;i=i+2
      while i<=n and depth>0 do
        local pair=sql:sub(i,i+1)
        if pair=='/*' then depth=depth+1;i=i+2
        elseif pair=='*/' then depth=depth-1;i=i+2
        else i=i+1 end
      end
      if depth~=0 then return false end
    else
      local word=sql:sub(i):match('^([%a_][%w_$]*)')
      return word and allowed[word:upper()] or false
    end
  end
  return false
end
local function positive(n) return type(n)=='number' and n>0 and n<=2147483647 and n%1==0 end
local function describe(value)
  local ok,text=pcall(tostring,value)
  return ok and text or 'error value could not be formatted'
end
local function problem(kind,message,phase,meta)
  return {kind=kind,message=describe(message),phase=phase,outcome='not_committed',
    sqlstate=meta and meta.sqlstate,metadata=meta}
end
local function query_error(message,phase,meta)
  return problem(meta and meta.failure_source or 'protocol',message,phase,meta)
end

local M={}
function M.new(config)
  assert(type(config)=='table','database config must be a table')
  local cfg={};for k,v in pairs(config) do cfg[k]=v end
  local pg=pgmoon.new(cfg)
  -- Never hand the private connection to a caller-supplied serializer. Arrays
  -- need NULL and pgvector needs no context; custom serializers get values only.
  local serializers={}
  for kind,fn in pairs(pg.type_serializers or {}) do serializers[kind]=fn end
  serializers.table=function(_,value)
    local mt=getmetatable(value)
    local fn=type(mt)=='table' and mt.pgmoon_serialize
    if type(fn)~='function' then return nil, "table does not implement pgmoon_serialize, can't serialize" end
    return fn(value,{NULL=pg.NULL})
  end
  pg.type_serializers=serializers
  local serial=queue()
  local timeout=cfg.timeout or 30000
  local active,connected,query_owner
  local db={}
  local function discard()
    connected=false
    -- The query wrapper has already closed transport failures. Disconnect also
    -- closes confirmed-but-unsynchronized streams before another queue owner runs.
    local ok,err=pg:disconnect()
    if not ok then return problem('cleanup',err,'disconnect') end
  end
  local function misuse(message)
    local e=problem('context',message,'callback')
    if active then active.failure=active.failure or e end
    return e
  end
  local function owner_bypass()
    if active and active.owner==coroutine.running() then return misuse('use the transaction context inside its callback') end
    if query_owner==coroutine.running() then return misuse('cannot reenter the database facade during a query') end
  end
  local function raw(sql,args,budget)
    pg:settimeout(math.max(1,math.floor(budget or timeout)))
    query_owner=coroutine.running()
    local result=table.pack(pg:extended_query(sql,unpack(args or {},1,args and args.n or 0)))
    query_owner=nil
    pg:settimeout(timeout)
    return result[1],result[2],result[7] or {failure_source='protocol',send_attempted=false}
  end
  local function remaining(ctx)
    return math.max(0,(ctx.deadline-skynet.now())*10)
  end
  local function expired(ctx)
    if remaining(ctx)<=0 then
      local e=problem('timeout','transaction deadline exceeded','callback')
      ctx.failure=ctx.failure or e;return e
    end
  end
  local function run_query(sql,args,ctx)
    if not permitted(sql) then
      local e=problem('sql_policy','SQL entry point is not allowed; use a single supported statement','query')
      if ctx then ctx.failure=ctx.failure or e end
      return nil,e
    end
    if not connected then return nil,problem('client','PostgreSQL is not connected','query') end
    local budget=timeout
    if ctx then
      if ctx.failure then return nil,ctx.failure end
      if expired(ctx) then return nil,ctx.failure end
      budget=math.min(timeout,remaining(ctx))
    end
    local rows,err,meta=raw(sql,args,budget)
    local expected=ctx and 'T' or 'I'
    local e
    if not rows then e=query_error(err,'query',meta)
    elseif meta.ready_for_query~=expected then e=problem('protocol','unexpected transaction state after query','query',meta) end
    if e then
      if not ctx and meta.send_attempted and meta.failure_source~='server' then
        e.outcome=(meta.ready_for_query=='I' and meta.command_tag) and 'committed' or 'unknown'
      end
      if ctx then ctx.failure=ctx.failure or e end
      local local_rejection=meta.failure_source=='client' and not meta.send_attempted and meta.connection_usable
      if meta.connection_usable==false or (not local_rejection and (not meta.ready_for_query or (not ctx and meta.ready_for_query~='I') or (ctx and meta.ready_for_query=='I'))) then
        e.cleanup_error=discard()
      end
      return nil,e
    end
    return rows,nil,meta
  end
  function db:connect()
    local e=owner_bypass();if e then return nil,e end
    return serial(function()
      if connected then return nil,problem('client','PostgreSQL is already connected','connect') end
      local ok,err=pg:connect();connected=not not ok
      if not ok then return nil,problem('connect',err,'connect') end
      return true
    end)
  end
  function db:disconnect()
    local e=owner_bypass();if e then return nil,e end
    return serial(function() local err=discard();if err then return nil,err end;return true end)
  end
  function db:query(sql,...)
    local e=owner_bypass();if e then return nil,e end
    local args=table.pack(...)
    return serial(function() return run_query(sql,args) end)
  end
  function db:transaction(fn,options)
    local e=owner_bypass();if e then return false,e end
    if type(fn)~='function' then return false,problem('config','transaction callback must be a function','begin') end
    options=options or {}
    if type(options)~='table' then return false,problem('config','transaction options must be a table','begin') end
    local function option(key,default) local v=options[key];if v==nil then return default end;return v end
    local opts={timeout=option('timeout',timeout),cleanup_timeout=option('cleanup_timeout',math.min(timeout,5000)),
      statement_timeout=option('statement_timeout',option('timeout',timeout)),
      idle_timeout=option('idle_timeout',option('timeout',timeout))}
    for k,v in pairs(opts) do if not positive(v) then return false,problem('config',k..' must be an integer from 1 to 2147483647 milliseconds','begin') end end
    return serial(function()
      if not connected then return false,problem('client','PostgreSQL is not connected','begin') end
      local ctx={owner=coroutine.running(),deadline=skynet.now()+math.max(1,math.ceil(opts.timeout/10)),live=true}
      local tx,abort_signal={},{}
      active=ctx
      local function check()
        if not ctx.live then return problem('context','transaction context has expired','callback') end
        if coroutine.running()~=ctx.owner then return misuse('transaction context belongs to another coroutine') end
        if expired(ctx) then return ctx.failure end
      end
      function tx:query(sql,...)
        local err=check();if err then return nil,err end
        return run_query(sql,table.pack(...),ctx)
      end
      function tx:abort(reason)
        local err=check();if err then return nil,err end
        ctx.failure=ctx.failure or problem('aborted',reason or 'transaction aborted','callback')
        error(abort_signal,0)
      end
      local function finish() ctx.live=false;active=nil end
      local function rollback(primary)
        ctx.live=false
        if connected then
          local ok,err,meta=raw('ROLLBACK',nil,opts.cleanup_timeout)
          if not ok or meta.command_tag~='ROLLBACK' or meta.ready_for_query~='I' then
            primary.cleanup_error=query_error(err or 'rollback did not confirm idle state','rollback',meta)
            primary.cleanup_error.disconnect_error=discard()
          end
        end
        finish();return false,primary
      end
      local began,err,meta=raw('BEGIN',nil,math.min(timeout,remaining(ctx)))
      if not began or meta.command_tag~='BEGIN' or meta.ready_for_query~='T' then
        local failure=query_error(err or 'BEGIN did not confirm transaction state','begin',meta)
        if meta.ready_for_query=='T' or meta.ready_for_query=='E' then return rollback(failure) end
        if meta.connection_usable==false or meta.ready_for_query~='I' then failure.cleanup_error=discard() end
        finish();return false,failure
      end
      local limits,limit_error=run_query("SELECT set_config('statement_timeout',$1,true), set_config('idle_in_transaction_session_timeout',$2,true)",
        table.pack(tostring(opts.statement_timeout)..'ms',tostring(opts.idle_timeout)..'ms'),ctx)
      if not limits then return rollback(limit_error) end
      local ok,value=pcall(fn,tx)
      ctx.live=false
      if not ok and value~=abort_signal then
        local failure=problem('callback',value,'callback');failure.cause=value
        ctx.failure=ctx.failure or failure
      end
      expired(ctx)
      if ctx.failure then return rollback(ctx.failure) end
      local committed,commit_error,commit_meta=raw('COMMIT',nil,math.min(timeout,remaining(ctx)))
      -- CommandComplete is definitive; losing later ReadyForQuery only retires
      -- the connection. Never report an acknowledged commit as unknown.
      if commit_meta.command_tag=='COMMIT' then
        commit_meta.outcome='committed'
        commit_meta.connection_usable=commit_meta.ready_for_query=='I' and not commit_meta.failure_source
        if not commit_meta.connection_usable then commit_meta.cleanup_error=discard() end
        finish();return true,value,commit_meta
      end
      local failure=query_error(commit_error or 'COMMIT did not commit the transaction','commit',commit_meta)
      if commit_meta.failure_source=='server' or commit_meta.command_tag=='ROLLBACK' or not commit_meta.send_attempted then
        failure.outcome='not_committed'
        if commit_meta.ready_for_query=='T' or commit_meta.ready_for_query=='E' then return rollback(failure) end
        if commit_meta.connection_usable==false or commit_meta.ready_for_query~='I' then failure.cleanup_error=discard() end
      else
        failure.outcome='unknown';failure.cleanup_error=discard()
      end
      finish();return false,failure
    end)
  end
  return db
end
return M
