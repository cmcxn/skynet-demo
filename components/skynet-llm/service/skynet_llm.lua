local skynet=require "skynet"
require "skynet.manager"
local driver=require "skynet.socketdriver"
local json=require "skynet_llm.json"
local config=require "skynet_llm.config"
local errors=require "skynet_llm.errors"
local scheduler=require "skynet_llm.scheduler"
local retry=require "skynet_llm.retry"
local commands={}
local settings,initial,groups,requests=nil,nil,{},{}
local sequence=0
local expired,expired_slots,expired_cursor={},{},1
local next_expiry_prune=0
local audit_queue,audit_active,audit_dropped={},false,0
local audit_thread
local dispatch,finish

local function err(code,stage,message,fields) return errors.new(code,stage,message,fields) end
local function wake(r)
    for _,key in ipairs{"wait_done","wait_event","wait_space"} do
        if r[key] then skynet.wakeup(r[key]); r[key]=nil end
    end
end
local function group_counts(g,exclude)
    local queued=0
    for _,r in pairs(requests) do if r~=exclude and r.group==g and not r.terminal and not r.active then queued=queued+1 end end
    return queued
end
local function owned(source,token)
    local r=requests[token]
    if not r then
        local previous=expired[token]
        if previous and previous.owner==source and previous.expires>skynet.now() then
            return nil,err("stream_expired","read","stream result retention expired",
                {request_id=previous.request_id,attempts=previous.attempts})
        end
        return nil,err("stream_closed","read","request is no longer available")
    end
    if r.owner~=source then return nil,err("stream_closed","read","request is no longer available") end
    return r
end
local function remember_expired(r,now)
    local previous=expired_slots[expired_cursor]
    if previous then expired[previous.token]=nil end
    local entry={token=r.token,owner=r.owner,expires=now+3000,
        request_id=r.options.request_id,attempts=r.attempts}
    expired[r.token]=entry; expired_slots[expired_cursor]=entry
    expired_cursor=expired_cursor%1024+1
end
local function release_body(r)
    if not r.body_released then r.body_released=true; r.group.pending_bytes=r.group.pending_bytes-r.length; r.body=nil end
end
local function release_stream(r)
    if r.streaming and not r.stream_released then
        r.stream_released=true; r.group.pending_streams=r.group.pending_streams-1
        r.events={}; r.event_bytes=0; wake(r)
    end
end
local function discard(r)
    release_stream(r)
    if not r.active then release_body(r); requests[r.token]=nil else r.discarded=true end
end
local function audit(r)
    if not settings or not settings.audit then return end
    local data={request_id=r.options.request_id,profile=r.profile_name,api=r.api,model=r.model,
        state=r.state,attempts=r.attempts,latency_ms=(skynet.now()-r.created)*10,
        http_status=r.http_status,usage=r.usage}
    local ok,encoded=pcall(json.encode,errors.redact(data,r.profile.api_key),{max_bytes=16*1024})
    if not ok or #encoded>16*1024 or #audit_queue+(audit_active and 1 or 0)>=256 then audit_dropped=audit_dropped+1; return end
    audit_queue[#audit_queue+1]=encoded
    if audit_active then return end
    audit_active=true
    local destination=settings.audit
    audit_thread=skynet.fork(function()
        while #audit_queue>0 do
            local next_record=table.remove(audit_queue,1)
            local delivered=pcall(skynet.call,destination.address,"lua",destination.command,next_record)
            if not delivered then audit_dropped=audit_dropped+1 end
        end
        audit_active=false; audit_thread=nil
    end)
end

finish=function(r,result,failure)
    if r.terminal then return end
    r.terminal=true; r.finished=skynet.now(); scheduler.remove(r.group.queue,r)
    r.result=result; r.error=failure and errors.annotate(failure,r)
    r.state=result and "completed" or (failure and failure.code=="cancelled" and "cancelled" or "failed")
    r.group[r.state]=r.group[r.state]+1
    r.group.latency_ms=r.group.latency_ms+(r.finished-r.created)*10
    local retention=r.streaming and r.profile.limits.result_retention_ms or math.min(30000,r.profile.limits.result_retention_ms)
    r.retention_deadline=r.finished+config.ticks(retention)
    if not r.active then release_body(r) end
    wake(r); audit(r)
end

local function cancel(r,failure)
    if not r.terminal then finish(r,nil,failure or err("cancelled","cancel","request cancelled",{may_have_executed=r.active or false})) end
    if r.worker then
        skynet.send(r.worker,"lua","cancel",r.token)
        local generation=r.generation
        skynet.timeout(100,function()
            if r.active and r.generation==generation then
                -- Killing a service releases its socket ownership in Skynet.
                pcall(skynet.kill,r.worker)
            end
        end)
    end
end

local function run(r)
    local g=r.group
    r.active=true; g.inflight=g.inflight+1
    r.attempts=r.attempts+1; r.generation=r.attempts
    r.queue_ms=r.queue_ms+(skynet.now()-r.queued_at)*10
    g.queue_ms=g.queue_ms+(skynet.now()-r.queued_at)*10
    r.state="connecting"
    r.thread=skynet.fork(function()
        local created,worker=pcall(skynet.newservice,"skynet_llm_worker",skynet.self())
        local result,failure
        if created then
            r.worker=worker
            if not r.terminal then
                local ok,a,b=pcall(skynet.call,worker,"lua","run",r.profile,r.api,r.body,r.options,r.token,skynet.self(),r.streaming)
                if ok then result,failure=a,errors.unpack(b) else failure=err("worker_failed","read","request worker failed",{may_have_executed=true}) end
            end
            pcall(skynet.kill,worker)
        else failure=err("worker_failed","connect","request worker could not start") end
        r.worker=nil; r.fd=nil; r.thread=nil; r.active=false; g.inflight=g.inflight-1
        if not r.terminal then
            if result then
                local decoded_ok,envelope=pcall(json.decode,result)
                if decoded_ok then
                    envelope.meta=envelope.meta or {}
                    envelope.meta.request_id=r.options.request_id; envelope.meta.attempts=r.attempts
                    envelope.meta.queue_ms=r.queue_ms; envelope.meta.latency_ms=(skynet.now()-r.created)*10
                    r.http_status=envelope.meta.http_status; r.usage=envelope.data and envelope.data.usage
                    finish(r,json.encode(envelope))
                else finish(r,nil,err("worker_failed","decode","worker returned an invalid result")) end
            else
                failure=failure or err("worker_failed","read","request worker returned no result")
                r.http_status=failure.http_status
                local delay=retry.delay(failure,r.attempts,r.options.retry,(r.options.deadline_tick-skynet.now())*10,r.delivered)
                if delay and settings then
                    if group_counts(g,r)>=g.budget.max_queue then failure.retry_stopped="queue_full"; finish(r,nil,failure)
                    else
                        -- An attempt that delivered nothing may be retried; its buffered
                        -- events must not become visible alongside the replacement.
                        r.events={}; r.event_bytes=0; r.next_sequence=0; r.ack=0
                        r.state="retry_wait"; r.queued_at=skynet.now(); r.ready_at=r.queued_at+config.ticks(delay)
                        r.queue_deadline=math.min(r.options.deadline_tick,r.ready_at+config.ticks(r.options.queue_timeout_ms))
                        g.queue[#g.queue+1]=r; g.retries=g.retries+1
                    end
                else failure.retryable=false; finish(r,nil,failure) end
            end
        end
        if r.terminal then release_body(r) end
        if r.discarded then discard(r) end
        dispatch(g)
    end)
end

dispatch=function(g)
    if not settings then return end
    while g.inflight<g.budget.max_inflight do
        local r=scheduler.pop(g.queue,skynet.now())
        if not r then break end
        run(r)
    end
end

local function worker_died(r)
    if not r.active then return end
    if r.fd then pcall(driver.shutdown,r.fd); pcall(driver.close,r.fd); r.fd=nil end
    if r.thread then skynet.killthread(r.thread); r.thread=nil end
    r.worker=nil; r.active=false; r.group.inflight=r.group.inflight-1
    if not r.terminal then finish(r,nil,err("worker_failed","read","request worker exited",{may_have_executed=true})) end
    release_body(r)
    if r.discarded then discard(r) end
    dispatch(r.group)
end

function commands.connection(source,token,fd)
    local r=requests[token]
    if r and r.worker==source then r.fd=fd end
    return true
end

function commands.start(_,encoded)
    local ok,input=pcall(json.decode,encoded)
    if not ok then return nil,err("invalid_request","validate","invalid configuration JSON") end
    if settings then
        if config.equal(initial,input) then return true end
        return nil,err("already_started","validate","model manager already has a different configuration")
    end
    for _,r in pairs(requests) do if r.active then return nil,err("already_started","validate","model manager is still stopping") end end
    local validated,failure=config.validate(input,function(name) return os.getenv(name) or skynet.getenv(name) end)
    if not validated then return nil,failure end
    for _,profile in pairs(validated.profiles) do
        if profile.base_url:sub(1,8)=="https://" then
            local loaded,tls=pcall(require,"skynet_llm.transport.tls")
            if not loaded then return nil,err("tls_error","tls","TLS adapter is unavailable") end
            local valid,tls_err=tls.validate(profile); if not valid then return nil,tls_err end
        end
    end
    settings=validated; initial=input; groups={}; requests={}; audit_queue={}; audit_dropped=0
    expired={}; expired_slots={}; expired_cursor=1
    for name,budget in pairs(settings.budgets) do
        groups[name]={budget=budget,queue={},inflight=0,pending_bytes=0,pending_streams=0,
            completed=0,failed=0,cancelled=0,retries=0,queue_ms=0,latency_ms=0}
    end
    return true
end

function commands.profile(_,name)
    if not settings then return nil,err("not_started","validate","model manager is not started") end
    local p=settings.profiles[name]
    if not p then return nil,err("unknown_profile","validate","unknown model profile") end
    return config.public(p)
end

function commands.reserve(source,name,api,length,options,streaming)
    if not settings then return nil,err("not_started","queue","model manager is not started") end
    local profile=settings.profiles[name]
    if not profile then return nil,err("unknown_profile","validate","unknown model profile") end
    if api~="chat" and api~="responses" and api~="embeddings" then return nil,err("invalid_request","validate","unknown API") end
    if profile.capabilities[api..(streaming and "_stream" or "")]~=true then return nil,err("unsupported_capability","validate","API is not enabled") end
    if type(length)~="number" or length<1 or length%1~=0 or length>profile.limits.max_request_bytes then return nil,err("invalid_request","validate","invalid request body length") end
    if type(options)~="table" or type(options.deadline_tick)~="number" or options.deadline_tick<=skynet.now() then return nil,err("timeout","queue","request deadline expired") end
    local g=groups[profile.budget_group]
    if group_counts(g)+g.inflight>=g.budget.max_queue+g.budget.max_inflight then return nil,err("queue_full","queue","model request queue is full") end
    if g.pending_bytes+length>math.min(g.budget.max_pending_bytes,profile.limits.max_pending_bytes) then return nil,err("queue_full","queue","pending request byte budget is full") end
    if streaming and g.pending_streams>=math.min(g.budget.max_pending_streams,profile.limits.max_pending_streams) then return nil,err("queue_full","queue","pending stream budget is full") end
    sequence=sequence+1
    local token=string.format("%x:%d",skynet.self(),sequence)
    local now=skynet.now()
    local r={token=token,order=sequence,owner=source,profile_name=name,profile=profile,group=g,api=api,
        length=length,options=options,streaming=streaming,created=now,queued_at=now,attempts=0,queue_ms=0,
        state="reserved",upload_deadline=math.min(options.deadline_tick,now+100),
        queue_deadline=math.min(options.deadline_tick,now+config.ticks(options.queue_timeout_ms)),
        events={},event_bytes=0,next_sequence=0,last_consumed=now,ack=0}
    requests[token]=r; g.pending_bytes=g.pending_bytes+length
    if streaming then g.pending_streams=g.pending_streams+1 end
    return token
end

function commands.submit(source,token,body)
    local r,failure=owned(source,token); if not r then return nil,failure end
    if r.terminal then return nil,r.error end
    if r.state~="reserved" or type(body)~="string" or #body~=r.length then
        finish(r,nil,err("invalid_request","validate","body upload must match its reservation exactly once"))
        discard(r); return nil,r.error
    end
    if skynet.now()>=r.upload_deadline then finish(r,nil,err("queue_timeout","queue","request upload reservation expired")); discard(r); return nil,r.error end
    local ok,data=pcall(json.decode,body)
    if not ok then finish(r,nil,err("invalid_request","validate","invalid request JSON")); discard(r); return nil,r.error end
    r.body=body; r.model=data.model; r.state="queued"; r.group.queue[#r.group.queue+1]=r
    dispatch(r.group)
    return true
end

function commands.await(source,token)
    local r,failure=owned(source,token); if not r then return nil,failure end
    if r.streaming then return nil,err("invalid_request","read","use stream consumption for a streaming request") end
    if r.wait_done then return nil,err("concurrent_read","read","request already has a reader") end
    while not r.terminal do r.wait_done={}; skynet.wait(r.wait_done) end
    local result,call_err=r.result,r.error
    discard(r)
    return result,call_err
end

function commands.event(source,token,encoded,raw,kind)
    local r=requests[token]
    if not r or r.worker~=source or r.terminal then return nil,err("cancelled","cancel","request is no longer active") end
    local size=#encoded+#(raw.data or "")
    if size>r.profile.limits.max_stream_buffer_bytes then return nil,err("invalid_response","protocol","stream event exceeds buffer limit") end
    while #r.events>=r.profile.limits.max_stream_events or r.event_bytes+size>r.profile.limits.max_stream_buffer_bytes do
        if r.terminal then return nil,r.error or err("cancelled","cancel","request ended") end
        r.wait_space={}; skynet.wait(r.wait_space)
    end
    if r.terminal then return nil,r.error or err("cancelled","cancel","request ended") end
    if #r.events==0 then r.last_consumed=skynet.now() end
    r.next_sequence=r.next_sequence+1
    r.events[#r.events+1]={sequence=r.next_sequence,encoded=encoded,raw_data=raw.data,kind=kind,
        meta={request_id=r.options.request_id,event_id=raw.id}}
    r.event_bytes=r.event_bytes+size
    if r.wait_event then skynet.wakeup(r.wait_event); r.wait_event=nil end
    return true
end

local function acknowledge(r,ack)
    if type(ack)~="number" or ack<r.ack or ack>r.next_sequence then return end
    if ack>r.ack then
        while r.events[1] and r.events[1].sequence<=ack do
            local e=table.remove(r.events,1); r.event_bytes=r.event_bytes-#e.encoded-#e.raw_data
        end
        r.ack=ack; r.last_consumed=skynet.now()
        if r.wait_space then skynet.wakeup(r.wait_space); r.wait_space=nil end
    end
end

function commands.next(source,token,ack)
    local r,failure=owned(source,token); if not r then return nil,failure end
    if r.expired then return nil,r.error end
    if not r.streaming or r.stream_released then return nil,err("stream_closed","read","stream is closed") end
    if r.wait_event then return nil,err("concurrent_read","read","stream already has a reader") end
    acknowledge(r,ack)
    while #r.events==0 and not r.terminal do r.wait_event={}; skynet.wait(r.wait_event) end
    if r.events[1] then r.delivered=true; return r.events[1] end
    return nil,r.error
end

function commands.result(source,token,ack)
    local r,failure=owned(source,token); if not r then return nil,failure end
    if r.expired then local expired=r.error; discard(r); return nil,expired end
    if not r.streaming or r.stream_released then return nil,err("stream_closed","read","stream is closed") end
    acknowledge(r,ack)
    if not r.terminal or #r.events>0 then return nil,err("invalid_request","read","consume stream events before taking its result") end
    local result,call_err=r.result,r.error
    discard(r)
    return result,call_err
end

function commands.cancel(source,token,close_stream)
    local r=requests[token]
    if not r or r.owner~=source then return true,close_stream and err("stream_closed","cancel","stream is closed") or nil end
    local already=r.terminal
    local before_upload=r.state=="reserved"
    cancel(r)
    if close_stream then
        local failure=already and err("stream_closed","cancel","stream is closed") or r.error
        discard(r); return true,failure
    end
    if before_upload then discard(r) end
    return true
end

function commands.stats()
    local result={started=settings~=nil,groups={},audit_dropped=audit_dropped}
    result.expired_cache=0
    for _,entry in pairs(expired) do if entry.expires>skynet.now() then result.expired_cache=result.expired_cache+1 end end
    for name,g in pairs(groups) do
        local retained,pending=0,0
        for _,r in pairs(requests) do
            if r.group==g then
                pending=pending+1
                if r.streaming and r.terminal and not r.stream_released then retained=retained+1 end
            end
        end
        result.groups[name]={inflight=g.inflight,queued=group_counts(g),pending_bytes=g.pending_bytes,
            pending_streams=g.pending_streams,pending_requests=pending,retained_results=retained,succeeded=g.completed,
            failed=g.failed,cancelled=g.cancelled,retries=g.retries,queue_ms=g.queue_ms,latency_ms=g.latency_ms}
    end
    return result
end

function commands.stop()
    settings=nil
    if audit_thread then skynet.killthread(audit_thread); audit_thread=nil end
    audit_dropped=audit_dropped+#audit_queue+(audit_active and 1 or 0)
    audit_queue={}; audit_active=false
    for _,r in pairs(requests) do cancel(r); if r.streaming or not r.wait_done then discard(r) end end
    return true
end

skynet.start(function()
    skynet.dispatch("lua",function(_,source,command,...)
        local fn=commands[command]
        if not fn then skynet.retpack(nil,err("invalid_request","validate","unknown manager command")); return end
        local ok,a,b=pcall(fn,source,...)
        if not ok then skynet.retpack(nil,err("worker_failed","queue","model manager operation failed")) else skynet.retpack(a,errors.pack(b)) end
    end)
    skynet.fork(function()
        while true do
            skynet.sleep(1)
            local now=skynet.now()
            for _,r in pairs(requests) do
                if not r.terminal then
                    if now>=r.options.deadline_tick then cancel(r,err("timeout",r.active and "read" or "queue","request deadline expired",{may_have_executed=r.active or false}))
                    elseif r.state=="reserved" and now>=r.upload_deadline then finish(r,nil,err("queue_timeout","queue","request upload reservation expired")); discard(r)
                    elseif not r.active and now>=r.queue_deadline then finish(r,nil,err("queue_timeout","queue","request queue deadline expired"))
                    elseif r.wait_space and now-r.last_consumed>=config.ticks(r.profile.limits.consumer_timeout_ms) then cancel(r,err("consumer_too_slow","read","stream consumer did not make progress",{may_have_executed=true})) end
                elseif r.streaming and not r.stream_released and now>=r.retention_deadline then
                    remember_expired(r,now)
                    r.result=nil; r.usage=nil; r.error=errors.annotate(err("stream_expired","read","stream result retention expired"),r)
                    r.expired=true; discard(r)
                elseif not r.streaming and now>=r.retention_deadline then
                    discard(r)
                end
            end
            if now>=next_expiry_prune then
                next_expiry_prune=now+100
                for slot,entry in pairs(expired_slots) do
                    if entry.expires<=now then expired[entry.token]=nil; expired_slots[slot]=nil end
                end
            end
            for _,g in pairs(groups) do dispatch(g) end
        end
    end)
    skynet.fork(function()
        while true do
            skynet.sleep(100)
            local owners={}
            for _,r in pairs(requests) do owners[r.owner]=true end
            for owner in pairs(owners) do
                skynet.fork(function()
                    local alive=pcall(skynet.call,owner,"debug","STAT")
                    if not alive then
                        for _,r in pairs(requests) do if r.owner==owner then cancel(r); discard(r) end end
                    end
                end)
            end
        end
    end)
    skynet.fork(function()
        while true do
            skynet.sleep(10)
            local ok,services=pcall(skynet.call,".launcher","lua","LIST")
            if ok then
                for _,r in pairs(requests) do
                    if r.active and r.worker and not services[skynet.address(r.worker)] then worker_died(r) end
                end
            end
        end
    end)
end)
