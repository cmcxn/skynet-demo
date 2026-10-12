local json = require "skynet_llm.json"
local M = {}
local function object(v) return json.kind(v) == "object" end
local function array(v)
    if json.kind(v) ~= "array" then return false end
    -- Explicitly tagged arrays may be assembled from indexed stream events.
    -- The marker carries the container kind, not a guarantee of density.
    local count=0
    for key in pairs(v) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count=count+1
    end
    for i=1,count do if rawget(v,i) == nil then return false end end
    return true
end
local function text(v) return type(v) == "string" and #v > 0 end
local function integer(v) return type(v) == "number" and v >= 0 and v < math.huge and v % 1 == 0 end
local function present(v) return v ~= nil and v ~= json.null end
local function failure(message,request,code,data)
    return nil,{code=code or (request and "invalid_request" or "invalid_response"),stage=request and "validate" or "protocol",message=message,retryable=false,partial_data=data,provider_error=data and data.error}
end
local function copy(v) return json.decode(json.encode(v)) end
local function unwrap(res)
    if object(res) and object(res.data) then return res.data end
    return res
end

function M.validate_request(body,profile,options)
    if not object(body) or not text(body.model) then return failure("responses requires a model",true) end
    if body.input ~= nil and type(body.input) ~= "string" and not array(body.input) then return failure("input must be a string or item array",true) end
    if array(body.input) then
        for _, item in ipairs(body.input) do if not object(item) then return failure("input items must be objects",true) end end
    end
    if body.input == nil and not present(body.previous_response_id) and not present(body.conversation) then return failure("responses requires input or state",true) end
    if present(body.previous_response_id) and present(body.conversation) then return failure("conversation and previous_response_id are mutually exclusive",true) end
    if body.background == true then return failure("background responses are unsupported",true,"unsupported_capability") end
    if body.background ~= nil and type(body.background) ~= "boolean" then return failure("background must be boolean",true) end
    if body.store ~= nil and type(body.store) ~= "boolean" then return failure("store must be boolean",true) end
    if body.stream ~= nil and type(body.stream) ~= "boolean" then return failure("stream must be boolean",true) end
    if body.tools ~= nil and not array(body.tools) then return failure("tools must be an array",true) end
    return true
end

function M.validate_response(body,data,options)
    if not object(data) then return failure("responses requires a JSON object") end
    if data.status ~= "completed" then return failure("response did not complete: " .. tostring(data.status),false,nil,data) end
    if not text(data.id) or not array(data.output) then return failure("response requires id and output array",false,nil,data) end
    local ids, calls = {},{}
    for _, item in ipairs(data.output) do
        if not object(item) or not text(item.type) then return failure("invalid response output item",false,nil,data) end
        if item.id ~= nil then
            if not text(item.id) or ids[item.id] then return failure("invalid or duplicate output item ID",false,nil,data) end
            ids[item.id]=true
        end
        if item.type == "message" then
            if not array(item.content) then return failure("message requires content array",false,nil,data) end
            for _, part in ipairs(item.content) do
                if not object(part) or not text(part.type) or (part.type == "output_text" and type(part.text) ~= "string") or (part.type == "refusal" and type(part.refusal) ~= "string") then return failure("invalid response content part",false,nil,data) end
            end
        elseif item.type == "function_call" then
            if not text(item.call_id) or calls[item.call_id] or not text(item.name) or type(item.arguments) ~= "string" then return failure("invalid function call",false,nil,data) end
            if item.status ~= nil and item.status ~= "completed" then return failure("incomplete function call",false,nil,data) end
            calls[item.call_id]=true
        elseif item.type == "reasoning" then
            if item.summary ~= nil then
                if not array(item.summary) then return failure("reasoning requires a dense summary array",false,nil,data) end
                for _, part in ipairs(item.summary) do
                    if not object(part) or not text(part.type) or (part.type == "summary_text" and type(part.text) ~= "string") then return failure("invalid reasoning summary part",false,nil,data) end
                end
            end
            if item.content ~= nil then
                if not array(item.content) then return failure("reasoning requires a dense content array",false,nil,data) end
                for _, part in ipairs(item.content) do
                    if not object(part) or not text(part.type) or (part.type == "reasoning_text" and type(part.text) ~= "string") then return failure("invalid reasoning content part",false,nil,data) end
                end
            end
        end
    end
    return true
end

-- Accepts the public result wrapper or the native response object.
function M.output_text(res)
    local data=unwrap(res); local parts={}
    if not object(data) or not array(data.output) then return "" end
    for _, item in ipairs(data.output) do
        if object(item) and item.type == "message" and array(item.content) then
            for _, part in ipairs(item.content) do
                if object(part) and part.type == "output_text" and type(part.text) == "string" then parts[#parts+1]=part.text end
            end
        end
    end
    return table.concat(parts)
end

function M.new_accumulator(body)
    local response=json.object{output=json.array{}}
    local items, ids, terminal, err = {}, {}, false, nil
    local acc={}
    local function bad(message,code,provider)
        local _, e=failure(message,false,code,response); err=e
        if provider then err.provider_error=provider end
        return nil,err
    end
    local function associated(event)
        if not integer(event.output_index) then return nil,"missing output index" end
        local item=items[event.output_index]
        if not item then return nil,"delta before output item" end
        if event.item_id ~= nil and item.id ~= event.item_id then return nil,"mismatched item ID/output index" end
        return item
    end
    local function install(index,item)
        if not integer(index) or not object(item) or not text(item.id) or not text(item.type) then return nil,"invalid output item event" end
        if items[index] and items[index].id ~= item.id then return nil,"output index changed identity" end
        if ids[item.id] ~= nil and ids[item.id] ~= index then return nil,"duplicate output item ID" end
        items[index]=copy(item); ids[item.id]=index
        return true
    end
    local function assembled()
        local list=json.array{}; local count=0
        for _ in pairs(items) do count=count+1 end
        for i=0,count-1 do
            if not items[i] then return nil,"sparse output indices" end
            list[#list+1]=items[i]
        end
        return list
    end
    function acc:push(event)
        if err then return nil,err end
        if terminal then return bad("event after terminal response") end
        if not object(event) or not text(event.type) then return bad("malformed Responses event") end
        local kind=event.type
        if kind == "response.failed" or kind == "response.incomplete" or kind == "error" then
            if object(event.response) then response=copy(event.response) end
            return bad("Responses stream failed: " .. kind,nil,event.error or event)
        elseif kind == "response.completed" then
            if not object(event.response) then return bad("completed event missing response") end
            local final=copy(event.response)
            if next(items) and (final.output == nil or (array(final.output) and #final.output == 0)) then
                local list,message=assembled(); if not list then return bad(message) end
                final.output=list
            end
            local ok,e=M.validate_response(body,final)
            if not ok then err=e; return nil,err end
            response=final; terminal=true; return true
        elseif kind == "response.created" or kind == "response.in_progress" or kind == "response.queued" then
            if not object(event.response) then return bad("response event missing response") end
            for k,v in pairs(event.response) do response[k]=copy(v) end
            if array(event.response.output) then
                for i,item in ipairs(event.response.output) do local ok,message=install(i-1,item); if not ok then return bad(message) end end
            end
        elseif kind == "response.output_item.added" or kind == "response.output_item.done" then
            local ok,message=install(event.output_index,event.item); if not ok then return bad(message) end
        elseif kind == "response.function_call_arguments.delta" or kind == "response.function_call_arguments.done" then
            local item,message=associated(event); if not item then return bad(message) end
            if item.type ~= "function_call" then return bad("function arguments for nonfunction item") end
            local value=kind:sub(-5) == ".done" and event.arguments or event.delta
            if type(value) ~= "string" then return bad("invalid arguments event") end
            if kind:sub(-5) == ".done" then item.arguments=value else item.arguments=(item.arguments or "") .. value end
        elseif kind == "response.content_part.added" or kind == "response.content_part.done" or kind == "response.reasoning_part.added" or kind == "response.reasoning_part.done" then
            local item,message=associated(event); if not item then return bad(message) end
            local reasoning=kind:find("reasoning_part",1,true)
            if item.type ~= (reasoning and "reasoning" or "message") or not integer(event.content_index) or not object(event.part) then return bad("invalid content part event") end
            item.content=item.content or json.array{}
            item.content[event.content_index+1]=copy(event.part)
        elseif kind == "response.output_text.delta" or kind == "response.output_text.done" or kind == "response.refusal.delta" or kind == "response.refusal.done" or kind == "response.reasoning_text.delta" or kind == "response.reasoning_text.done" then
            local item,message=associated(event); if not item then return bad(message) end
            local reasoning=kind:find("reasoning_text",1,true)
            if item.type ~= (reasoning and "reasoning" or "message") or not integer(event.content_index) then return bad("invalid text event association") end
            local refusal=kind:find("refusal",1,true); local field=refusal and "refusal" or "text"
            local part_type=refusal and "refusal" or (reasoning and "reasoning_text" or "output_text")
            local value=kind:sub(-5) == ".done" and event[field] or event.delta
            if type(value) ~= "string" then return bad("invalid text event") end
            item.content=item.content or json.array{}
            local part=item.content[event.content_index+1]
            if not part then part=json.object{type=part_type}; item.content[event.content_index+1]=part end
            if part.type ~= part_type then return bad("content part changed type") end
            if kind:sub(-5) == ".done" then part[field]=value else part[field]=(part[field] or "") .. value end
        elseif kind == "response.reasoning_summary_part.added" or kind == "response.reasoning_summary_part.done" then
            local item,message=associated(event); if not item then return bad(message) end
            if item.type ~= "reasoning" or not integer(event.summary_index) or not object(event.part) then return bad("invalid reasoning summary part") end
            item.summary=item.summary or json.array{}; item.summary[event.summary_index+1]=copy(event.part)
        elseif kind == "response.reasoning_summary_text.delta" or kind == "response.reasoning_summary_text.done" then
            local item,message=associated(event); if not item then return bad(message) end
            if item.type ~= "reasoning" or not integer(event.summary_index) then return bad("invalid reasoning summary association") end
            local value=kind:sub(-5) == ".done" and event.text or event.delta
            if type(value) ~= "string" then return bad("invalid reasoning text") end
            item.summary=item.summary or json.array{}
            local part=item.summary[event.summary_index+1] or json.object{type="summary_text",text=""}; item.summary[event.summary_index+1]=part
            if kind:sub(-5) == ".done" then part.text=value else part.text=(part.text or "") .. value end
        end
        return true
    end
    function acc:finish()
        if err then return nil,err end
        if not terminal then
            local list=assembled(); if list then response.output=list end
            return failure("Responses stream ended without response.completed",false,"stream_interrupted",response)
        end
        return response
    end
    return acc
end

return M
