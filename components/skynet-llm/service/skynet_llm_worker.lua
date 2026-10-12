local skynet=require "skynet"
local socket=require "skynet.socket"
local json=require "skynet_llm.json"
local errors=require "skynet_llm.errors"
local http=require "skynet_llm.transport.http"
local manager_owner=tonumber((...))
local active
local endpoints={chat="/chat/completions",responses="/responses",embeddings="/embeddings"}

local function run(profile,api,body_json,options,token,manager,streaming)
    if active then return nil,errors.new("worker_failed","connect","worker already has an active request") end
    local call={token=token,cancelled=false}; active=call
    local watch_token={}
    local watcher=skynet.fork(function()
        while active==call do
            skynet.sleep(10,watch_token)
            if active~=call then return end
            local ok,services=pcall(skynet.call,".launcher","lua","LIST")
            if ok and not services[skynet.address(manager)] then
                call.cancelled=true; call.orphaned=true
                if call.fd then pcall(socket.shutdown,call.fd) end
                return
            end
        end
    end)
    local function execute()
        local protocol=require("skynet_llm.protocol."..api)
        local body=json.decode(body_json)
        local accumulator=streaming and protocol.new_accumulator(body)
        local raw_bytes=0
        local transport_options={}
        for k,v in pairs(options) do transport_options[k]=v end
        transport_options.cancelled=function() return call.cancelled end
        transport_options.on_fd=function(fd)
            call.fd=fd
            skynet.send(manager,"lua","connection",token,fd)
        end
        local function event(raw)
            raw_bytes=raw_bytes+#raw.data
            if raw_bytes>profile.limits.max_stream_bytes then return nil,errors.new("invalid_response","protocol","stream exceeds cumulative byte limit",{may_have_executed=true}) end
            local decoded
            if api=="chat" and raw.data=="[DONE]" then decoded="[DONE]"
            else
                local ok,data=pcall(json.decode,raw.data)
                if not ok then return nil,errors.new("invalid_json","decode","invalid JSON in stream event",{may_have_executed=true}) end
                decoded=data
            end
            local valid,failure=accumulator:push(decoded)
            if not valid then return nil,failure end
            if decoded=="[DONE]" then return true,"done" end
            local encoded=json.encode(decoded)
            local kind=api=="chat" and "chat.chunk" or decoded.type or raw.event
            local accepted,event_err=skynet.call(manager,"lua","event",token,encoded,raw,kind)
            if not accepted then return nil,event_err end
            if api=="responses" and decoded.type=="response.completed" then return true,"done" end
            return true
        end
        local response,failure=http.request(profile,endpoints[api],body_json,transport_options,streaming and event or nil)
        if not response then return nil,failure end
        if response.status<200 or response.status>=300 then
            local provider_error
            if #response.body<=16*1024 then local ok,data=pcall(json.decode,response.body); if ok then provider_error=data end end
            return nil,errors.new("http_error","read","model server returned an HTTP error",{
                http_status=response.status,may_have_executed=true,provider_error=provider_error,
                retry_after=response.headers["retry-after"],retryable=true})
        end
        local data
        if streaming then
            data,failure=accumulator:finish(); if not data then return nil,failure end
        else
            local ok,decoded=pcall(json.decode,response.body)
            if not ok then return nil,errors.new("invalid_json","decode","model server returned invalid JSON",{http_status=response.status,may_have_executed=true}) end
            data=decoded
            local valid,validation_err=protocol.validate_response(body,data,options)
            if not valid then return nil,validation_err end
        end
        local result={data=data,raw_json=not streaming and response.body or nil,
            meta={http_status=response.status,provider_request_id=response.headers["x-request-id"],assembled=streaming or false}}
        if streaming then
            local bounded=pcall(json.encode,data,{max_bytes=profile.limits.max_result_bytes})
            if not bounded then return nil,errors.new("invalid_response","protocol","result exceeds byte limit",{may_have_executed=true}) end
        end
        local encoded=json.encode(result)
        return encoded
    end
    local ok,result,failure=pcall(execute)
    if call.fd then pcall(socket.shutdown,call.fd); pcall(socket.close,call.fd); call.fd=nil end
    active=nil
    skynet.wakeup(watch_token)
    if call.orphaned then skynet.timeout(0,skynet.exit) end
    if not ok then return nil,errors.new("worker_failed","read","request worker failed",{may_have_executed=true}) end
    return result,errors.pack(errors.redact(failure,profile.api_key))
end

skynet.start(function()
    if manager_owner then
        skynet.fork(function()
            while true do
                skynet.sleep(10)
                local ok,services=pcall(skynet.call,".launcher","lua","LIST")
                if ok and not services[skynet.address(manager_owner)] then
                    if active then
                        active.cancelled=true; active.orphaned=true
                        if active.fd then pcall(socket.shutdown,active.fd) end
                    else skynet.exit() end
                    return
                end
            end
        end)
    end
    skynet.dispatch("lua",function(_,_,command,...)
        if command=="run" then skynet.retpack(run(...))
        elseif command=="cancel" then
            local token=...
            if active and active.token==token then
                active.cancelled=true
                if active.fd then pcall(socket.shutdown,active.fd) end
            end
            skynet.retpack(true)
        else skynet.retpack(nil,errors.new("invalid_request","validate","unknown worker command")) end
    end)
end)
