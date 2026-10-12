local M = {}

function M.new(code, stage, message, fields)
    local err = {code=code, stage=stage, message=message, retryable=false, may_have_executed=false}
    for k,v in pairs(fields or {}) do err[k] = v end
    return err
end

function M.annotate(err, request)
    if type(err) ~= "table" then err = M.new("worker_failed", "read", "request worker failed") end
    err.request_id = request.options.request_id
    err.attempts = request.attempts or 0
    if err.retryable == nil then err.retryable = false end
    if err.may_have_executed == nil then err.may_have_executed = false end
    return err
end

-- RPC metadata stays plain; native JSON error details keep their container types.
function M.pack(err)
    if type(err)~="table" then return err end
    local out={}; for k,v in pairs(err) do out[k]=v end
    if out.provider_error~=nil or out.partial_data~=nil then
        out.encoded_details=require("skynet_llm.json").encode{
            provider_error=out.provider_error,partial_data=out.partial_data}
        out.provider_error=nil; out.partial_data=nil
    end
    return out
end

function M.unpack(err)
    if type(err)~="table" or not err.encoded_details then return err end
    local ok,details=pcall(require("skynet_llm.json").decode,err.encoded_details)
    err.encoded_details=nil
    if ok then err.provider_error=details.provider_error; err.partial_data=details.partial_data end
    return err
end

function M.redact(value,secret)
    if not secret or secret=="" then return value end
    if type(value)=="string" then
        local parts,pos={},1
        while true do
            local first,last=value:find(secret,pos,true)
            if not first then parts[#parts+1]=value:sub(pos); break end
            parts[#parts+1]=value:sub(pos,first-1); parts[#parts+1]="[REDACTED]"; pos=last+1
        end
        return table.concat(parts)
    elseif type(value)=="table" then
        local renamed={}
        for k,v in pairs(value) do
            local key=type(k)=="string" and M.redact(k,secret) or k
            local redacted=M.redact(v,secret)
            if key==k then value[k]=redacted
            else value[k]=nil; renamed[key]=redacted end
        end
        -- Redacted keys win collisions: preserving secrets is never necessary for diagnostics.
        for k,v in pairs(renamed) do value[k]=v end
    end
    return value
end

return M
