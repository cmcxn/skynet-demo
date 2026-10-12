local errors = require "skynet_llm.errors"
local M = {}
local MiB = 1024*1024
local limits = {max_request_bytes=32*MiB,max_response_bytes=32*MiB,max_header_bytes=32*1024,
    max_event_bytes=MiB,max_stream_events=64,max_stream_buffer_bytes=MiB,
    max_stream_bytes=32*MiB,max_result_bytes=32*MiB,max_pending_bytes=64*MiB,
    max_pending_streams=16,consumer_timeout_ms=5000,result_retention_ms=30000}
local defaults = {timeout_ms=30000,stream_timeout_ms=120000,queue_timeout_ms=3000,
    connect_timeout_ms=5000,idle_timeout_ms=15000,priority=2}
local forbidden = {host=true,["content-length"]=true,["transfer-encoding"]=true,
    connection=true,authorization=true,["proxy-authorization"]=true,["accept-encoding"]=true,
    ["x-api-key"]=true,["api-key"]=true,cookie=true,["set-cookie"]=true}
local function invalid(message) return nil,errors.new("invalid_request","validate",message) end
local function positive(n) return type(n)=="number" and n>0 and n<math.huge and n==n end
local function copy(t) local o={}; for k,v in pairs(t or {}) do o[k]=v end; return o end

function M.ticks(ms) return math.ceil(ms/10) end

function M.retry(input, base)
    if input ~= nil and type(input) ~= "table" then return invalid("retry must be an object") end
    local r = copy(base or {max_attempts=2,base_delay_ms=250,max_delay_ms=2000,allow_ambiguous=false})
    for k,v in pairs(input or {}) do r[k]=v end
    for _,k in ipairs{"max_attempts","base_delay_ms","max_delay_ms"} do
        if not positive(r[k]) then return invalid("retry limits must be finite positive numbers") end
    end
    if r.max_attempts%1~=0 or r.max_attempts>100 then return invalid("max_attempts must be an integer from 1 to 100") end
    if type(r.allow_ambiguous)~="boolean" then return invalid("allow_ambiguous must be boolean") end
    if r.statuses~=nil then
        if type(r.statuses)~="table" then return invalid("retry statuses must be an array") end
        for _,v in pairs(r.statuses) do if not positive(v) or v%1~=0 or v<500 or v>599 then return invalid("extra retry statuses must be 5xx") end end
    end
    return r
end

function M.options(profile, supplied, streaming, now)
    if supplied~=nil and type(supplied)~="table" then return invalid("options must be an object") end
    local o=copy(profile.defaults)
    o.timeout_ms=streaming and o.stream_timeout_ms or o.timeout_ms
    local allowed={timeout_ms=true,queue_timeout_ms=true,connect_timeout_ms=true,idle_timeout_ms=true,
        priority=true,request_id=true,expected_dimensions=true,retry=true,cancel_token=true}
    for k,v in pairs(supplied or {}) do
        if not allowed[k] then return invalid("unknown local option") end
        if k~="cancel_token" then o[k]=v end
    end
    for _,k in ipairs{"timeout_ms","queue_timeout_ms","connect_timeout_ms","idle_timeout_ms"} do
        if not positive(o[k]) then return invalid(k.." must be finite and positive") end
    end
    if o.priority~=1 and o.priority~=2 and o.priority~=3 then return invalid("priority must be 1, 2 or 3") end
    if o.request_id~=nil and (type(o.request_id)~="string" or #o.request_id>256 or o.request_id:find("[%z\1-\31]")) then return invalid("request_id must be a bounded printable string") end
    if o.expected_dimensions~=nil and (not positive(o.expected_dimensions) or o.expected_dimensions%1~=0) then return invalid("expected_dimensions must be a positive integer") end
    local retry,err=M.retry(o.retry,profile.retry); if not retry then return nil,err end
    o.retry=retry
    o.deadline_tick=now+M.ticks(o.timeout_ms)
    return o
end

function M.validate(input, getenv)
    if type(input)~="table" or type(input.profiles)~="table" or next(input.profiles)==nil then return invalid("profiles must be a nonempty object") end
    if input.budgets~=nil and type(input.budgets)~="table" then return invalid("budgets must be an object") end
    local out={profiles={},budgets={},audit=input.audit}
    for name,p in pairs(input.profiles) do
        if type(name)~="string" or name=="" or #name>128 or type(p)~="table" then return invalid("invalid profile") end
        local q=copy(p)
        if type(p.base_url)~="string" or p.base_url:find("[%s%z?#@]") then return invalid("base_url must have no credentials, query, fragment or whitespace") end
        local scheme,authority,path=p.base_url:match("^(https?)://([^/]+)(/.*)$")
        if not scheme or not authority or authority:find("[%[%]]") then return invalid("base_url needs an explicit base path; IPv6 is not supported") end
        local host,port=authority:match("^([%w%.%-]+):(%d+)$")
        if not host then host=authority; if not host:match("^[%w%.%-]+$") then return invalid("invalid base_url host") end end
        if port and (tonumber(port)<1 or tonumber(port)>65535) then return invalid("invalid base_url port") end
        if scheme=="http" and p.allow_http~=true then return invalid("HTTP requires allow_http=true") end
        q.base_url=p.base_url:gsub("/+$","")
        if path=="/" then return invalid("base_url needs an explicit base path") end
        q.budget_group=p.budget_group or name
        if type(q.budget_group)~="string" or q.budget_group=="" then return invalid("budget_group must be a name") end
        if p.capabilities~=nil and type(p.capabilities)~="table" then return invalid("capabilities must be an object") end
        q.capabilities=copy(p.capabilities)
        for _,v in pairs(q.capabilities) do if type(v)~="boolean" then return invalid("capability values must be boolean") end end
        if p.headers~=nil and type(p.headers)~="table" then return invalid("headers must be an object") end
        q.headers=copy(p.headers)
        for k,v in pairs(q.headers) do
            if type(k)~="string" or not k:match("^[!#$%%&'*+.^_`|~%w%-]+$") or forbidden[k:lower()] or type(v)~="string" or v:find("[\r\n%z]") then return invalid("invalid or reserved fixed header") end
        end
        if p.api_key~=nil then return invalid("credentials must use api_key_env") end
        if p.auth=="none" then q.api_key=nil
        elseif p.auth==nil or p.auth=="bearer" then
            if type(p.api_key_env)~="string" or p.api_key_env=="" then return invalid("authenticated profiles need api_key_env") end
            q.api_key=getenv(p.api_key_env)
            if type(q.api_key)~="string" or q.api_key=="" or q.api_key:find("[\r\n%z]") then return invalid("credential environment variable is missing or invalid") end
            q.auth="bearer"
        else return invalid("unsupported authentication type") end
        q.defaults=copy(defaults)
        if p.defaults~=nil and type(p.defaults)~="table" then return invalid("defaults must be an object") end
        for k in pairs(defaults) do
            local v=p[k] or (p.defaults and p.defaults[k]); if v~=nil then q.defaults[k]=v end
            if not positive(q.defaults[k]) then return invalid("profile defaults must be finite and positive") end
        end
        if q.defaults.priority~=1 and q.defaults.priority~=2 and q.defaults.priority~=3 then return invalid("profile priority must be 1, 2 or 3") end
        q.limits=copy(limits)
        if p.limits~=nil and type(p.limits)~="table" then return invalid("limits must be an object") end
        for k in pairs(limits) do
            if p.limits and p.limits[k]~=nil then q.limits[k]=p.limits[k] end
            if not positive(q.limits[k]) or q.limits[k]%1~=0 then return invalid("resource limits must be finite positive integers") end
        end
        local r,err=M.retry(p.retry); if not r then return nil,err end; q.retry=r
        if p.tls~=nil and type(p.tls)~="table" then return invalid("tls must be an object") end
        if p.tls and p.tls.use_default_ca==false and not p.tls.ca_file and not p.tls.ca_path then return invalid("disabling default CAs requires an explicit CA") end
        out.profiles[name]=q
        if not out.budgets[q.budget_group] then
            local supplied=input.budgets and input.budgets[q.budget_group]
            if supplied~=nil and type(supplied)~="table" then return invalid("budget must be an object") end
            local b=copy(supplied)
            b.max_inflight=b.max_inflight or 4; b.max_queue=b.max_queue or 64
            b.max_pending_bytes=b.max_pending_bytes or limits.max_pending_bytes
            b.max_pending_streams=b.max_pending_streams or limits.max_pending_streams
            for _,k in ipairs{"max_inflight","max_queue","max_pending_bytes","max_pending_streams"} do
                if not positive(b[k]) or b[k]%1~=0 then return invalid("budget limits must be finite positive integers") end
            end
            out.budgets[q.budget_group]=b
        end
    end
    if out.audit~=nil and (type(out.audit)~="table" or (type(out.audit.address)~="number" and type(out.audit.address)~="string") or type(out.audit.command)~="string") then return invalid("audit needs a service address and command") end
    return out
end

function M.public(profile)
    return {capabilities=copy(profile.capabilities),defaults=copy(profile.defaults),
        limits=copy(profile.limits),retry=copy(profile.retry),budget_group=profile.budget_group}
end

function M.equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not M.equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end

return M
