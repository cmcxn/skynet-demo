-- Pure continuation helpers. No tools are executed here.
-- Result arguments accept either native response data or {data=native_data}.
local json = require "skynet_llm.json"
local M = {}
local function object(v) return json.kind(v) == "object" end
local function array(v) return json.kind(v) == "array" end
local function text(v) return type(v) == "string" and #v > 0 end
local function present(v) return v ~= nil and v ~= json.null end
local function bad(message,code)
    error({code=code or "invalid_request",stage="validate",message=message,retryable=false},0)
end
local function need(condition,message,code) if not condition then bad(message,code) end end
local function copy(v) return json.decode(json.encode(v)) end
local function guard(fn)
    return function(...)
        local ok,value=pcall(fn,...)
        if ok then return value end
        if type(value) == "table" and value.code then return nil,value end
        return nil,{code="invalid_request",stage="validate",message=tostring(value),retryable=false}
    end
end
local function unwrap(res)
    if object(res) and object(res.data) then return res.data end
    return res
end
local function function_call(call,chat)
    need(object(call),"tool call must be an object")
    need(call.type == (chat and "function" or "function_call"),"only function tool continuation is supported","unsupported_continuation")
    need(call.status == nil or call.status == "completed","function call is incomplete")
    local fn=chat and call["function"] or call
    need(object(fn) and text(fn.name) and type(fn.arguments) == "string","function call is incomplete")
    need(text(chat and call.id or call.call_id),"function call is missing its call ID")
    return fn
end
local function outputs_for(calls,results,id_key,chat)
    need(array(results),"tool results must be an array")
    local wanted,results_by_id={},{}
    for _, call in ipairs(calls) do
        function_call(call,chat)
        local id=chat and call.id or call.call_id
        need(not wanted[id],"duplicate function call ID")
        wanted[id]=true
    end
    need(next(wanted) ~= nil,"response contains no function calls")
    for _, result in ipairs(results) do
        need(object(result) and text(result[id_key]) and type(result.output) == "string","each result needs a call ID and string output")
        local id=result[id_key]
        need(wanted[id],"unknown tool result ID")
        need(results_by_id[id] == nil,"duplicate tool result ID")
        results_by_id[id]=result.output
    end
    for id in pairs(wanted) do need(results_by_id[id] ~= nil,"missing tool result ID: " .. id) end
    return results_by_id
end

M.decode_arguments=guard(function(call)
    local fn=function_call(call,object(call) and call.type == "function")
    local ok,value=pcall(json.decode,fn.arguments)
    if not ok then bad("invalid function arguments JSON: " .. tostring(value),"invalid_json") end
    return value
end)

M.continue_chat=guard(function(original,result,results,opts)
    opts=opts or {}; need(object(opts),"continuation options must be an object")
    need(object(original) and array(original.messages) and #original.messages > 0,"original chat messages are required")
    local data=unwrap(result)
    need(object(data) and array(data.choices) and #data.choices > 0,"chat choices are required")
    local choice
    if opts.choice_index == nil then
        need(#data.choices == 1,"choice_index is required for multiple choices")
        choice=data.choices[1]
    else
        need(type(opts.choice_index)=="number" and opts.choice_index >= 0 and opts.choice_index % 1 == 0,"invalid choice_index")
        for _, candidate in ipairs(data.choices) do
            need(object(candidate),"invalid chat choice")
            if candidate.index == opts.choice_index then need(not choice,"duplicate selected choice index"); choice=candidate end
        end
        need(choice ~= nil,"selected choice not found")
    end
    need(object(choice) and choice.finish_reason == "tool_calls","choice did not finish with complete tool calls")
    local message=choice.message
    need(object(message) and message.role == "assistant" and array(message.tool_calls) and #message.tool_calls > 0,"complete assistant tool calls are required")
    local outputs=outputs_for(message.tool_calls,results,"tool_call_id",true)
    local next_body=copy(original)
    next_body.messages[#next_body.messages+1]=copy(message)
    for _, call in ipairs(message.tool_calls) do
        next_body.messages[#next_body.messages+1]=json.object{role="tool",tool_call_id=call.id,content=outputs[call.id]}
    end
    return next_body
end)

M.continue_responses=guard(function(original,result,results,opts)
    opts=opts or {}; need(object(opts),"continuation options must be an object")
    need(object(original),"original Responses request must be an object")
    local data=unwrap(result)
    need(object(data) and data.status == "completed" and array(data.output),"a completed response is required")
    need(not present(original.conversation),"conversation continuation is unsupported","unsupported_continuation")
    local calls=json.array{}
    for _, item in ipairs(data.output) do
        need(object(item) and text(item.type),"invalid response output item")
        if item.type == "function_call" then calls[#calls+1]=item end
    end
    local outputs=outputs_for(calls,results,"call_id",false)
    local mode=opts.mode or "replay"
    need(mode == "replay" or mode == "previous_response_id","unknown continuation mode","unsupported_continuation")
    local next_body=copy(original); local input=json.array{}
    if mode == "previous_response_id" then
        need(original.store == true and data.store == true and text(data.id),"state continuation requires a stored request and response ID","unsupported_continuation")
        next_body.store=true; next_body.previous_response_id=data.id
    else
        need(not present(original.previous_response_id),"replay cannot recover omitted state-chain history","unsupported_continuation")
        if type(original.input) == "string" then input[1]=json.object{role="user",content=original.input}
        elseif array(original.input) then input=copy(original.input)
        else bad("replay requires original input items","unsupported_continuation") end
        for _, item in ipairs(data.output) do
            if item.type == "reasoning" then
                need(text(item.encrypted_content),"reasoning replay requires encrypted_content","unsupported_continuation")
            elseif item.type == "message" then
                need(array(item.content),"message replay requires complete content","unsupported_continuation")
            elseif item.type ~= "function_call" then bad("unsupported replay output type: " .. item.type,"unsupported_continuation") end
            input[#input+1]=copy(item)
        end
        next_body.store=false; next_body.previous_response_id=nil
    end
    for _, call in ipairs(calls) do input[#input+1]=json.object{type="function_call_output",call_id=call.call_id,output=outputs[call.call_id]} end
    next_body.input=input
    return next_body
end)

return M
