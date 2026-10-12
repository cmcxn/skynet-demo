local json = require "skynet_llm.json"
local M = {}
local function object(v) return json.kind(v) == "object" end
local function array(v) return json.kind(v) == "array" end
local function text(v) return type(v) == "string" and #v > 0 end
local function integer(v) return type(v) == "number" and v >= 0 and v < math.huge and v % 1 == 0 end
local function failure(message, request, code)
    return nil, {code=code or (request and "invalid_request" or "invalid_response"),stage=request and "validate" or "protocol",message=message,retryable=false}
end
local function copy(v) return json.decode(json.encode(v)) end
local function valid_calls(calls)
    if not array(calls) or #calls == 0 then return false end
    local ids = {}
    for _, call in ipairs(calls) do
        if not object(call) or not text(call.id) or ids[call.id] or not text(call.type) then return false end
        ids[call.id] = true
        if call.type == "function" then
            if not object(call["function"]) or not text(call["function"].name) or type(call["function"].arguments) ~= "string" then return false end
        end
    end
    return true
end

function M.validate_request(body, profile, options)
    if not object(body) or not text(body.model) or not array(body.messages) or #body.messages == 0 then
        return failure("chat requires model and a nonempty messages array",true)
    end
    for _, message in ipairs(body.messages) do
        if not object(message) or not text(message.role) then return failure("invalid chat message",true) end
    end
    if body.n ~= nil and (not integer(body.n) or body.n == 0) then return failure("n must be a positive integer",true) end
    if body.stream ~= nil and type(body.stream) ~= "boolean" then return failure("stream must be boolean",true) end
    if body.tools ~= nil and not array(body.tools) then return failure("tools must be an array",true) end
    return true
end

function M.validate_response(body, data, options)
    if not object(data) or not array(data.choices) or #data.choices == 0 then return failure("chat response requires choices") end
    local indices = {}
    for _, choice in ipairs(data.choices) do
        if not object(choice) or not integer(choice.index) or indices[choice.index] then return failure("invalid or duplicate choice index") end
        indices[choice.index] = true
        local message=choice.message
        if not object(message) or message.role ~= "assistant" or not text(choice.finish_reason) then return failure("incomplete chat choice") end
        if message.content ~= nil and message.content ~= json.null and type(message.content) ~= "string" and not array(message.content) then return failure("invalid message content") end
        if message.tool_calls ~= nil and not valid_calls(message.tool_calls) then return failure("invalid tool calls") end
    end
    local expected=(body and body.n) or 1
    if not integer(expected) or expected == 0 or #data.choices ~= expected then return failure("unexpected number of choices") end
    for i=0,expected-1 do if not indices[i] then return failure("missing choice index") end end
    return true
end

function M.new_accumulator(body)
    local expected = body.n or 1
    local data = json.object{object="chat.completion",choices=json.array{}}
    local choices, calls, done, err = {}, {}, false, nil
    local acc = {}
    local function bad(message)
        local _, e=failure(message); err=e; err.partial_data=data
        return nil,err
    end
    local function merge_string(target, key, fragment)
        if type(fragment) ~= "string" then return false end
        target[key]=(target[key] or "") .. fragment
        return true
    end
    function acc:push(chunk)
        if err then return nil,err end
        if done then return bad("event after chat DONE") end
        if chunk == "[DONE]" then
            for i=0,expected-1 do
                if not choices[i] or not text(choices[i].finish_reason) then return bad("DONE before all choices finished") end
            end
            data.choices=json.array{}
            for i=0,expected-1 do
                local choice=choices[i]
                if calls[i] then
                    local list=json.array{}; local count=0
                    for _ in pairs(calls[i]) do count=count+1 end
                    for j=0,count-1 do
                        if not calls[i][j] then return bad("sparse tool call indices") end
                        list[#list+1]=calls[i][j]
                    end
                    choice.message.tool_calls=list
                end
                data.choices[#data.choices+1]=choice
            end
            local ok,e=M.validate_response({n=expected},data)
            if not ok then err=e; err.partial_data=data; return nil,err end
            done=true; return true
        end
        if not object(chunk) or not array(chunk.choices) then return bad("malformed chat chunk") end
        if chunk.error ~= nil then return bad("provider error in chat stream") end
        for k,v in pairs(chunk) do
            if k ~= "choices" and k ~= "object" then data[k]=copy(v) end
        end
        local seen={}
        for _, part in ipairs(chunk.choices) do
            if not object(part) or not integer(part.index) or part.index >= expected or seen[part.index] or not object(part.delta) then return bad("invalid chat chunk choice") end
            seen[part.index]=true
            local index=part.index; local choice=choices[index]
            if not choice then choice=json.object{index=index,message=json.object{role="assistant",content=json.null},finish_reason=json.null}; choices[index]=choice end
            local delta=part.delta
            if choice.finish_reason ~= json.null then
                if next(delta) ~= nil or (part.finish_reason ~= nil and part.finish_reason ~= json.null) then return bad("delta after choice finish_reason") end
            else
                for key,value in pairs(delta) do
                    if key == "content" then
                        if value ~= json.null then
                            if type(value) ~= "string" then return bad("invalid content delta") end
                            local current=choice.message.content
                            choice.message.content=(current == json.null and "" or current or "") .. value
                        end
                    elseif key == "refusal" or key == "reasoning_content" then
                        if value ~= json.null and not merge_string(choice.message,key,value) then return bad("invalid text delta") end
                    elseif key == "role" then
                        if value ~= "assistant" then return bad("invalid assistant role") end
                        choice.message.role=value
                    elseif key == "tool_calls" then
                        if not array(value) then return bad("invalid tool call delta array") end
                        calls[index]=calls[index] or {}
                        local seen_calls={}
                        for _, fragment in ipairs(value) do
                            if not object(fragment) or not integer(fragment.index) or seen_calls[fragment.index] then return bad("invalid tool call delta index") end
                            seen_calls[fragment.index]=true
                            local call=calls[index][fragment.index]
                            if not call then call=json.object{}; calls[index][fragment.index]=call end
                            for k,v in pairs(fragment) do
                                if k == "id" then
                                    if not merge_string(call,k,v) then return bad("invalid tool id fragment") end
                                elseif k == "type" then
                                    if not text(v) or (call.type and call.type ~= v) then return bad("inconsistent tool type") end
                                    call.type=v
                                elseif k == "function" then
                                    if not object(v) then return bad("invalid function delta") end
                                    call[k]=call[k] or json.object{}
                                    for field, f in pairs(v) do
                                        if field == "name" or field == "arguments" then
                                            if not merge_string(call[k],field,f) then return bad("invalid function fragment") end
                                        else call[k][field]=copy(f) end
                                    end
                                elseif k ~= "index" then call[k]=copy(v) end
                            end
                        end
                    else choice.message[key]=copy(value) end
                end
                if part.finish_reason ~= nil and part.finish_reason ~= json.null then
                    if not text(part.finish_reason) then return bad("invalid finish_reason") end
                    choice.finish_reason=part.finish_reason
                end
            end
            for key,value in pairs(part) do
                if key ~= "index" and key ~= "delta" and key ~= "finish_reason" then choice[key]=copy(value) end
            end
        end
        return true
    end
    function acc:finish()
        if err then return nil,err end
        if not done then local _,e=failure("chat stream ended without DONE",false,"stream_interrupted"); e.partial_data=data; return nil,e end
        return data
    end
    return acc
end

return M
