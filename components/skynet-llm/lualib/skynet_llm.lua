local skynet = require "skynet"
local json = require "skynet_llm.json"
local config = require "skynet_llm.config"
local errors = require "skynet_llm.errors"
local M = {json=json,tools=require "skynet_llm.tools",chat=require "skynet_llm.protocol.chat",
    responses=require "skynet_llm.protocol.responses",embeddings=require "skynet_llm.protocol.embeddings"}
local manager,serial
serial=0

local function rpc_at(deadline,command,...)
    if not manager then
        local ok,address=pcall(skynet.uniqueservice,"skynet_llm")
        if not ok then return nil,errors.new("service_unavailable","queue","model manager is unavailable") end
        manager=address
    end
    local address=manager
    local arguments=table.pack(...)
    local wait_token,watch_token={},{}
    local complete,values=false
    local call_thread=skynet.fork(function()
        local ok,a,b,c=pcall(skynet.call,address,"lua",command,table.unpack(arguments,1,arguments.n))
        if complete then return end
        complete=true
        if ok then values=table.pack(a,errors.unpack(b),c)
        else
            if manager==address then manager=nil end
            values=table.pack(nil,errors.new("service_unavailable","queue","model manager is unavailable"))
        end
        skynet.wakeup(wait_token)
    end)
    local watcher=skynet.fork(function()
        while not complete do
            skynet.sleep(math.max(1,math.min(10,deadline-skynet.now())),watch_token)
            if complete then return end
            local failure
            if skynet.now()>=deadline then
                failure=errors.new("timeout",(command=="await" or command=="next") and "read" or "queue","model manager RPC deadline expired",
                    {may_have_executed=command=="await" or command=="next"})
            else
                local alive,services=pcall(skynet.call,".launcher","lua","LIST")
                if alive and not services[skynet.address(address)] then
                    if manager==address then manager=nil end
                    failure=errors.new("service_unavailable","read","model manager exited",{may_have_executed=command=="await" or command=="next"})
                end
            end
            if failure and not complete then
                complete=true; values=table.pack(nil,failure)
                skynet.killthread(call_thread); skynet.wakeup(wait_token)
                return
            end
        end
    end)
    skynet.wait(wait_token)
    skynet.wakeup(watch_token)
    return table.unpack(values,1,values.n)
end
local function rpc(command,...) return rpc_at(skynet.now()+1000,command,...) end

function M.start(input)
    local ok,encoded=pcall(json.encode,input)
    if not ok then return nil,errors.new("invalid_request","validate","configuration is not valid JSON") end
    return rpc("start",encoded)
end
function M.stop() return rpc("stop") end
function M.stats() return rpc("stats") end

local Cancel={}; Cancel.__index=Cancel
function M.cancel_token() return setmetatable({owner=skynet.self(),cancelled=false},Cancel) end
function Cancel:cancel()
    if self.owner~=skynet.self() then return nil,errors.new("invalid_request","cancel","cancel token belongs to another service") end
    self.cancelled=true
    if self.token then rpc("cancel",self.token) end
    return true
end

local Stream={}; Stream.__index=Stream
local function stream_error(err)
    if err and err.code=="stream_closed" then
        return errors.new("stream_expired","read","stream result is no longer retained")
    end
    return err
end
local function unpack_result(encoded)
    local ok,result=pcall(json.decode,encoded)
    if not ok then return nil,errors.new("invalid_response","decode","manager returned an invalid result") end
    return result
end
function Stream:_next()
    if self.error then return nil,self.error end
    if self.done then return nil end
    local event,err=rpc_at(math.max(self.deadline,skynet.now()+100),"next",self.token,self.ack)
    err=stream_error(err)
    if not event then
        self.done=true; self.error=err
        return nil,err
    end
    self.ack=event.sequence
    local ok,data=pcall(json.decode,event.encoded)
    if not ok then self.error=errors.new("invalid_response","decode","invalid stream event"); return nil,self.error end
    return {kind=event.kind,data=data,raw_data=event.raw_data,meta=event.meta}
end
function Stream:next()
    if self.reading then return nil,errors.new("concurrent_read","read","stream already has a reader") end
    self.reading=true
    local ok,value,err=pcall(self._next,self)
    self.reading=false
    if not ok then return nil,errors.new("service_unavailable","read","stream reader failed") end
    return value,err
end
function Stream:result()
    if self.reading then return nil,errors.new("concurrent_read","read","stream already has a reader") end
    if self.result_value then return self.result_value end
    if self.result_error then return nil,self.result_error end
    self.reading=true
    local ok,value,err=pcall(function()
        while not self.done do local event,read_err=self:_next(); if read_err or not event then break end end
        local encoded,result_err=rpc("result",self.token,self.ack)
        result_err=stream_error(result_err)
        if not encoded then return nil,self.error or result_err end
        return unpack_result(encoded)
    end)
    self.reading=false
    if not ok then value=nil; err=errors.new("service_unavailable","read","stream reader failed") end
    if value then self.result_value=value else self.result_error=err end
    return value,err
end
function Stream:cancel()
    if self.result_value or self.result_error then return true end
    local ok,err=rpc("cancel",self.token,true)
    self.done=true
    self.error=err or errors.new("cancelled","cancel","request cancelled")
    self.result_error=self.error
    return ok or true
end

local Client={}; Client.__index=Client
local function capability(profile,api,streaming)
    local name=api..(streaming and "_stream" or "")
    if profile.capabilities[name]~=true then return nil,errors.new("unsupported_capability","validate","profile does not enable "..name) end
    return true
end

local function validate_capabilities(profile,api,body)
    local caps=profile.capabilities
    if api=="responses" and (body.store==true or body.previous_response_id~=nil or body.conversation~=nil) and caps.response_state~=true then
        return nil,errors.new("unsupported_capability","validate","profile does not enable response_state")
    end
    for _,tool in ipairs(type(body.tools)=="table" and body.tools or {}) do
        if json.kind(tool)~="object" or type(tool.type)~="string" then
            return nil,errors.new("invalid_request","validate","tools must contain objects with a type")
        end
        local name=tool.type=="function" and "function_tools" or (tool.type=="custom" and "custom_tools" or "hosted_tools")
        if caps[name]~=true then return nil,errors.new("unsupported_capability","validate","profile does not enable "..name) end
    end
    return true
end

function Client:_request(api,body,supplied,streaming)
    local now=skynet.now()
    local enabled,cap_err=capability(self.profile,api,streaming); if not enabled then return nil,cap_err end
    if supplied~=nil and type(supplied)~="table" then return nil,errors.new("invalid_request","validate","options must be an object") end
    local token=supplied and supplied.cancel_token
    if token then
        if getmetatable(token)~=Cancel or token.owner~=skynet.self() then return nil,errors.new("invalid_request","validate","invalid cancel token") end
        if token.used then return nil,errors.new("invalid_request","validate","cancel token has already been used") end
        token.used=true
        if token.cancelled then return nil,errors.new("cancelled","cancel","request cancelled") end
    end
    local options,option_err=config.options(self.profile,supplied,streaming,now)
    if not options then return nil,option_err end
    serial=serial+1
    options.request_id=options.request_id or string.format("%x-%d-%d",skynet.self(),now,serial)
    local ok,snapshot=pcall(function()
        return json.decode(json.encode(body,{max_bytes=self.profile.limits.max_request_bytes}))
    end)
    if not ok or type(snapshot)~="table" or snapshot==json.null then return nil,errors.new("invalid_request","validate","body must be a JSON object") end
    if streaming then snapshot.stream=true elseif snapshot.stream==true then return nil,errors.new("invalid_request","validate","use a streaming method for stream=true") end
    if api=="responses" and snapshot.store==nil then snapshot.store=false end
    if api=="embeddings" and snapshot.encoding_format==nil then snapshot.encoding_format="float" end
    local capable,capability_err=validate_capabilities(self.profile,api,snapshot)
    if not capable then return nil,capability_err end
    local valid,validation_err=M[api].validate_request(snapshot,self.profile,options)
    if not valid then return nil,validation_err end
    local encoded_ok,encoded=pcall(json.encode,snapshot,{max_bytes=self.profile.limits.max_request_bytes})
    if not encoded_ok then return nil,errors.new("invalid_request","validate","body cannot be encoded") end
    if #encoded>self.profile.limits.max_request_bytes then return nil,errors.new("invalid_request","validate","request body exceeds byte limit") end
    local id,admission_err=rpc_at(options.deadline_tick,"reserve",self.name,api,#encoded,options,streaming)
    if not id then return nil,admission_err end
    if token then token.token=id; if token.cancelled then rpc("cancel",id,true); return nil,errors.new("cancelled","cancel","request cancelled") end end
    local uploaded,upload_err=rpc_at(options.deadline_tick,"submit",id,encoded)
    if not uploaded then
        rpc("cancel",id,true)
        if token and token.cancelled then return nil,errors.new("cancelled","cancel","request cancelled") end
        return nil,upload_err
    end
    if token and token.cancelled then rpc("cancel",id,true); return nil,errors.new("cancelled","cancel","request cancelled") end
    if streaming then return setmetatable({token=id,ack=0,deadline=options.deadline_tick},Stream) end
    local response,err=rpc_at(options.deadline_tick+1,"await",id)
    if not response then if err then err.request_id=options.request_id end; return nil,err end
    return unpack_result(response)
end

for _,api in ipairs{"chat","responses","embeddings"} do
    Client[api]=function(self,body,options) return self:_request(api,body,options,false) end
end
for _,api in ipairs{"chat","responses"} do
    Client[api.."_stream"]=function(self,body,options) return self:_request(api,body,options,true) end
end

function M.client(name)
    if type(name)~="string" then return nil,errors.new("invalid_request","validate","profile name must be a string") end
    local profile,err=rpc("profile",name)
    if not profile then return nil,err end
    return setmetatable({name=name,profile=profile},Client)
end

return M
