local skynet = require "skynet"
local llm = require "skynet_llm"

if ...=="owner_exit" then
    skynet.start(function()
        local client=assert(llm.client("slow"))
        skynet.fork(function() client:chat({model="delay:2000",messages=llm.json.array{{role="user",content="hello"}}},{timeout_ms=5000}) end)
        skynet.sleep(10)
        skynet.exit()
    end)
    return
end
if ...=="audit_sink" then
    skynet.start(function()
        skynet.dispatch("lua",function(_,_,command)
            if command=="record" then skynet.wait() else skynet.retpack(true) end
        end)
    end)
    return
end

local function check(value, err)
    assert(value, err and (err.code .. ": " .. err.message) or "assertion failed")
    return value
end

local function wait_until(predicate)
    for _=1,300 do if predicate() then return end; skynet.sleep(1) end
    error("condition did not become true")
end

skynet.start(function()
    local ok, failure = xpcall(function()
        -- These literals catch regressions in policy without depending on wall-clock timing.
        local cfg=require "skynet_llm.config"
        local scheduler=require "skynet_llm.scheduler"
        local retry=require "skynet_llm.retry"
        local errors=require "skynet_llm.errors"
        local scrubbed=errors.redact({["fixture-secret-key"]="fixture-secret-key"},"fixture-secret-key")
        assert(not llm.json.encode(scrubbed):find("fixture-secret-key",1,true),"provider error object key leaked credential")
        local packed=errors.pack{code="invalid_response",provider_error={nullable=llm.json.null,empty=llm.json.array{}}}
        local restored=errors.unpack(skynet.unpack(skynet.pack(packed)))
        assert(restored.provider_error.nullable==llm.json.null and llm.json.kind(restored.provider_error.empty)=="array")
        local old={options={priority=1},queued_at=0,order=1}
        local new={options={priority=3},queued_at=201,order=2}
        assert(scheduler.pop({new,old},201)==old, "aging must prevent priority starvation")
        assert(scheduler.pop({{options={priority=2},queued_at=0,order=2},old},0).order==2)
        local policy={max_attempts=2,base_delay_ms=250,max_delay_ms=2000,allow_ambiguous=false}
        assert(retry.delay({http_status=503},1,policy,3000,false,function() return 0 end)==0)
        assert(retry.delay({http_status=401},1,policy,3000,false)==nil)
        assert(retry.delay({http_status=503},2,policy,3000,false)==nil)
        assert(retry.delay({http_status=503},1,policy,3000,true)==nil)
        assert(retry.delay({code="timeout",may_have_executed=true},1,policy,3000,false)==nil)
        assert(retry.retry_after("2",0)==2000)
        assert(retry.retry_after("Thu, 01 Jan 1970 00:00:02 GMT",0)==2000)
        assert(retry.delay({http_status=429,retry_after="2"},1,policy,1000,false)==nil)
        local rejected_config, rejected_config_err=cfg.validate({profiles={bad={base_url="http://mock/v1",auth="none"}}},function() end)
        assert(not rejected_config and rejected_config_err.code=="invalid_request")
        local key_config,key_err=cfg.validate({profiles={bad={base_url="https://mock/v1",api_key_env="TEST_KEY"}}},function() end)
        assert(not key_config and key_err.code=="invalid_request")
        local caps = {chat=true,chat_stream=true}
        local audit_sink=skynet.newservice("integration/lifecycle","audit_sink")
        check(llm.start{profiles={
            slow={base_url="http://mock:18080/delay/v1",auth="none",allow_http=true,
                capabilities=caps,budget_group="shared"},
            retry={base_url="http://mock:18080/retry/v1",auth="none",allow_http=true,
                capabilities=caps,budget_group="shared"},
        },budgets={shared={max_inflight=4,max_queue=2}},audit={address=audit_sink,command="record"}})
        local c = check(llm.client("slow"))
        local function body(ms) return {model="delay:"..ms,messages=llm.json.array{{role="user",content="hello"}}} end
        local done, results = 0, {}
        for i=1,6 do
            skynet.fork(function()
                results[i] = {c:chat(body(400),{timeout_ms=3000})}
                done = done + 1
            end)
        end
        wait_until(function() local s=llm.stats(); return s.groups.shared.inflight==4 and s.groups.shared.queued==2 end)
        local rejected, rejected_err = c:chat(body(20))
        assert(not rejected and rejected_err.code == "queue_full")
        wait_until(function() return done == 6 end)
        for i=1,6 do check(results[i][1],results[i][2]) end
        assert(llm.stats().groups.shared.inflight == 0)
        local services=skynet.call(".launcher","lua","LIST")
        for _,name in pairs(services) do assert(not name:find("skynet_llm_worker",1,true),"completed worker service leaked") end
        local manager_address=skynet.uniqueservice("skynet_llm")
        local baseline_tasks=skynet.call(manager_address,"debug","STAT").task
        local failed_worker
        skynet.fork(function() failed_worker={c:chat(body(1500))} end)
        wait_until(function() return llm.stats().groups.shared.inflight==1 end)
        wait_until(function()
            for address,name in pairs(skynet.call(".launcher","lua","LIST")) do
                if name:find("skynet_llm_worker",1,true) then skynet.call(".launcher","lua","KILL",address); return true end
            end
        end)
        wait_until(function() return failed_worker~=nil end)
        assert(not failed_worker[1] and failed_worker[2].code=="worker_failed")
        wait_until(function() return llm.stats().groups.shared.inflight==0 end)
        assert(skynet.call(manager_address,"debug","STAT").task==baseline_tasks,"dead worker RPC coroutine leaked")
        local token = llm.cancel_token()
        local cancelled
        skynet.fork(function() cancelled={c:chat(body(1000),{cancel_token=token})} end)
        wait_until(function() return llm.stats().groups.shared.inflight == 1 end)
        check(token:cancel()); check(token:cancel())
        wait_until(function() return cancelled ~= nil end)
        assert(not cancelled[1] and cancelled[2].code == "cancelled")
        wait_until(function() return llm.stats().groups.shared.inflight == 0 end)
        local expired, expired_err = c:chat(body(500),{timeout_ms=60})
        assert(not expired and expired_err.code == "timeout")
        wait_until(function() return llm.stats().groups.shared.inflight == 0 end)
        local retry_client = check(llm.client("retry"))
        local recovered, recovered_err = retry_client:chat({model="retry-once-lifecycle-"..tostring(skynet.time()),messages=body(1).messages})
        check(recovered,recovered_err)
        assert(recovered.meta.attempts == 2)
        local before_retry=llm.stats().groups.shared.retries
        local interrupted=check(c:chat_stream({model="cut-stream",messages=body(1).messages},
            {retry={allow_ambiguous=true,base_delay_ms=1,max_delay_ms=1}}))
        wait_until(function() local s=llm.stats().groups.shared; return s.retries==before_retry+1 and s.retained_results==1 end)
        local interrupted_count=0
        while true do
            local event,event_err=interrupted:next()
            if not event then assert(event_err and event_err.code=="stream_interrupted" and event_err.attempts==2); break end
            interrupted_count=interrupted_count+1
        end
        assert(interrupted_count==1,"retry retained stale attempt events")
        local _,interrupted_err=interrupted:result()
        assert(interrupted_err and interrupted_err.code=="stream_interrupted")
        local delivered=check(c:chat_stream({model="cut-stream",messages=body(1).messages},{retry={allow_ambiguous=true}}))
        check(delivered:next())
        local _,delivered_err=delivered:result()
        assert(delivered_err and delivered_err.attempts==1,"delivered stream event was replayed")
        local stream = check(c:chat_stream(body(500)))
        check(stream:cancel())
        local _, stream_err = stream:result()
        assert(stream_err and (stream_err.code == "cancelled" or stream_err.code == "stream_closed"))
        local concurrent=check(c:chat_stream(body(500)))
        local blocked
        skynet.fork(function() blocked={concurrent:next()} end)
        skynet.sleep(1)
        local _,concurrent_err=concurrent:result()
        assert(concurrent_err and concurrent_err.code=="concurrent_read")
        check(concurrent:cancel())
        wait_until(function() return blocked~=nil end)
        skynet.newservice("integration/lifecycle","owner_exit")
        wait_until(function() return llm.stats().groups.shared.inflight==1 end)
        wait_until(function() return llm.stats().groups.shared.inflight==0 end)
        wait_until(function() local s=llm.stats().groups.shared; return s.inflight==0 and s.pending_streams==0 and s.pending_bytes==0 end)
        local stats = llm.stats().groups.shared
        assert(stats.retries == 2 and stats.cancelled >= 3)
        for i=1,260 do
            local reserved=check(skynet.call(manager_address,"lua","reserve","slow","chat",1,
                {deadline_tick=skynet.now()+500,queue_timeout_ms=3000,priority=2,request_id="audit-limit-"..i,retry=policy},false))
            local uploaded,upload_err=skynet.call(manager_address,"lua","submit",reserved,"x")
            assert(not uploaded and upload_err.code=="invalid_request")
        end
        assert(llm.stats().audit_dropped>0,"busy audit delivery must stay bounded and count drops")
        check(c:chat(body(1)))
        check(llm.stop())
        skynet.call(".launcher","lua","KILL",audit_sink)
        -- A reservation without an upload must release its byte and stream budgets.
        check(llm.start{profiles={tiny={base_url="http://mock:18080/v1",auth="none",allow_http=true,
            capabilities=caps,limits={max_pending_bytes=500,max_pending_streams=1,
                max_stream_events=2,consumer_timeout_ms=50,result_retention_ms=50}}},
            budgets={tiny={max_inflight=1,max_queue=1}}})
        local manager=skynet.uniqueservice("skynet_llm")
        local local_options={deadline_tick=skynet.now()+500,queue_timeout_ms=3000,priority=2,
            request_id="reservation-test",retry=policy}
        local reservation=check(skynet.call(manager,"lua","reserve","tiny","chat",400,local_options,true))
        local over,over_err=skynet.call(manager,"lua","reserve","tiny","chat",100,local_options,true)
        assert(not over and over_err.code=="queue_full")
        local byte_over,byte_over_err=skynet.call(manager,"lua","reserve","tiny","chat",200,local_options,false)
        assert(not byte_over and byte_over_err.code=="queue_full")
        wait_until(function() return llm.stats().groups.tiny.pending_bytes==0 end)
        assert(llm.stats().groups.tiny.pending_streams==0)
        local late,late_err=skynet.call(manager,"lua","submit",reservation,string.rep("x",400))
        assert(not late and late_err.code=="stream_closed")
        local mismatch=check(skynet.call(manager,"lua","reserve","tiny","chat",400,local_options,false))
        local mismatch_uploaded,mismatch_err=skynet.call(manager,"lua","submit",mismatch,string.rep("x",399))
        assert(not mismatch_uploaded and mismatch_err.code=="invalid_request")
        assert(llm.stats().groups.tiny.pending_bytes==0)
        for _=1,128 do
            local before_upload=check(skynet.call(manager,"lua","reserve","tiny","chat",1,local_options,false))
            check(skynet.call(manager,"lua","cancel",before_upload))
        end
        assert(llm.stats().groups.tiny.pending_requests==0,"cancelled admission records leaked")
        local tiny=check(llm.client("tiny"))
        local delayed=check(tiny:chat_stream(body(250)))
        skynet.sleep(27)
        check(delayed:result())
        local abandoned=check(tiny:chat_stream(body(1)))
        skynet.sleep(20)
        local _,abandoned_err=abandoned:result()
        assert(abandoned_err and (abandoned_err.code=="consumer_too_slow" or abandoned_err.code=="stream_expired"))
        wait_until(function() return llm.stats().groups.tiny.pending_streams==0 end)
        local retained=check(tiny:chat_stream(body(1),{timeout_ms=1e12}))
        while true do local event,event_err=retained:next(); assert(not event_err,event_err and event_err.message); if not event then break end end
        skynet.sleep(10)
        assert(llm.stats().groups.tiny.pending_requests==0,"expired stream kept its full request record")
        local _,retained_err=retained:result()
        assert(retained_err and retained_err.code=="stream_expired")
        local encoded=llm.json.encode(body(1))
        local unclaimed_options={deadline_tick=skynet.now()+1e10,queue_timeout_ms=3000,priority=2,
            request_id="unclaimed-result",retry=policy}
        local unclaimed=check(skynet.call(manager,"lua","reserve","tiny","chat",#encoded,unclaimed_options,false))
        check(skynet.call(manager,"lua","submit",unclaimed,encoded))
        wait_until(function() return llm.stats().groups.tiny.inflight==0 end)
        skynet.sleep(10)
        assert(llm.stats().groups.tiny.pending_requests==0,"unclaimed result followed an unbounded request deadline")
        check(llm.stop())
        check(llm.start{profiles={death={base_url="http://mock:18080/delay/v1",auth="none",allow_http=true,capabilities=caps}}})
        local death=check(llm.client("death"))
        local manager_failure
        skynet.fork(function() manager_failure={death:chat(body(2000),{timeout_ms=5000})} end)
        wait_until(function() return llm.stats().groups.death.inflight==1 end)
        skynet.call(".launcher","lua","KILL",skynet.uniqueservice("skynet_llm"))
        wait_until(function() return manager_failure~=nil end)
        assert(not manager_failure[1] and manager_failure[2].code=="service_unavailable")
        wait_until(function()
            for _,name in pairs(skynet.call(".launcher","lua","LIST")) do if name:find("skynet_llm_worker",1,true) then return false end end
            return true
        end)
        skynet.error("PASS: shared concurrency, queue limits, cancellation, deadlines, retry and cleanup")
    end, debug.traceback)
    local f = assert(io.open("/tmp/skynet-llm-result", "w"))
    f:write(ok and "PASS\n" or "FAIL\n" .. tostring(failure)); f:close()
    if not ok then skynet.error(failure) end
    require("skynet.core").command("ABORT")
end)
