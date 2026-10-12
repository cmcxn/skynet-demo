local skynet = require "skynet"
local llm = require "skynet_llm"
local checks = {}
local function record(name, result, err, extra)
    local entry = {name=name, status=result and "PASS" or "FAIL"}
    if err then entry.code=err.code; entry.http_status=err.http_status; entry.stage=err.stage end
    for k,v in pairs(extra or {}) do entry[k]=v end
    checks[#checks+1]=entry
    skynet.error(entry.status .. ": real " .. name .. (entry.http_status and " HTTP "..entry.http_status or ""))
    return result
end
local function required(value, err)
    assert(value, err and (err.code or "request failed") or "assertion failed")
    return value
end
local function incompatible(name, err, reason, model)
    checks[#checks+1]={name=name,status="INCOMPATIBLE",code=err.code,stage=err.stage,reason=reason,model=model}
    skynet.error("INCOMPATIBLE: real "..name.." ("..reason..")")
end

skynet.start(function()
    local ok, failure = pcall(function()
        local caps={chat=true,chat_stream=true,responses=true,responses_stream=true,embeddings=true,function_tools=true}
        required(llm.start{profiles={
            main={base_url=assert(os.getenv("LLM_BASE_URL")),api_key_env="LLM_API_KEY",capabilities=caps,budget_group="main"},
            embedding={base_url=assert(os.getenv("EMBEDDING_BASE_URL")),api_key_env="LLM_API_KEY",capabilities=caps,budget_group="main"},
        }})
        local c=required(llm.client("main"))
        local e=required(llm.client("embedding"))
        local model=assert(os.getenv("LLM_MODEL"))
        local embedding_model=assert(os.getenv("EMBEDDING_MODEL"))
        local options={timeout_ms=60000,idle_timeout_ms=30000,retry={max_attempts=1}}
        local body={model=model,messages=llm.json.array{{role="user",content="只回答 OK"}},
            max_completion_tokens=128,chat_template_kwargs={enable_thinking=false}}
        local res,err=c:chat(body,options)
        record("chat",res and type(res.data.choices[1].message.content)=="string",err,{model=model})
        local stream,stream_err=c:chat_stream(body,options)
        local streamed,finish_err
        if stream then streamed,finish_err=stream:result() end
        record("chat_stream",streamed,stream_err or finish_err,{model=model})
        local tools=llm.json.array{{type="function",["function"]={name="get_order",description="查询订单",
            parameters={type="object",properties={order_id={type="string"}},required=llm.json.array{"order_id"},additionalProperties=false},strict=true}}}
        local tool_body={model=model,messages=llm.json.array{{role="user",content="请调用 get_order 查询订单 A123。"}},
            tools=tools,tool_choice={type="function",["function"]={name="get_order"}},
            max_completion_tokens=256,chat_template_kwargs={enable_thinking=false}}
        local tr,te=c:chat(tool_body,options)
        local calls=tr and tr.data.choices[1].message.tool_calls
        record("function_tools",calls and #calls>0,te,{model=model})
        if calls and #calls>0 then
            local outputs={}
            for _,call in ipairs(calls) do
                required(llm.tools.decode_arguments(call))
                outputs[#outputs+1]={tool_call_id=call.id,output='{"status":"paid"}'}
            end
            local next_body,next_err=llm.tools.continue_chat(tool_body,tr,outputs)
            required(next_body,next_err)
            next_body.tool_choice="none"
            local continuation,continuation_err=c:chat(next_body,options)
            record("tool_continuation",continuation,continuation_err,{model=model})
        end
        local tool_stream,tool_stream_err=c:chat_stream(tool_body,options)
        local streamed_tools,streamed_tools_err
        if tool_stream then streamed_tools,streamed_tools_err=tool_stream:result() end
        local streamed_calls=streamed_tools and streamed_tools.data.choices[1].message.tool_calls
        record("chat_tool_stream",streamed_calls and #streamed_calls>0,tool_stream_err or streamed_tools_err,{model=model})
        local embedding,embedding_err=e:embeddings({model=embedding_model,input=llm.json.array{"订单已经付款","订单等待付款"}},options)
        local vectors=embedding and llm.embeddings.vectors(embedding)
        record("embeddings",vectors and #vectors==2,embedding_err,{model=embedding_model,dimensions=vectors and #vectors[1] or 0})
        local response,response_err=c:responses({model=model,input="只回答 OK",max_output_tokens=128,store=false},options)
        if not response and response_err and (response_err.http_status==404 or response_err.http_status==405 or response_err.http_status==501) then
            checks[#checks+1]={name="responses",status="UNSUPPORTED",http_status=response_err.http_status,model=model}
            skynet.error("UNSUPPORTED: real Responses HTTP "..response_err.http_status)
        else
            record("responses",response,response_err,{model=model})
        end
        if response then
            local rs,rs_err=c:responses_stream({model=model,input="只回答 OK",max_output_tokens=128,store=false},options)
            local rs_result,rs_result_err
            if rs then rs_result,rs_result_err=rs:result() end
            local stream_failure=rs_err or rs_result_err
            if not rs_result and stream_failure and stream_failure.code=="invalid_response" and stream_failure.message=="invalid output item event" then
                incompatible("responses_stream",stream_failure,"provider_output_item_missing_index",model)
            else
                record("responses_stream",rs_result,stream_failure,{model=model})
            end
            local rb={model=model,input="请调用 get_order 查询订单 A123。",store=false,max_output_tokens=1024,
                tools=llm.json.array{{type="function",name="get_order",parameters=tools[1]["function"].parameters,strict=true}},
                tool_choice={type="function",name="get_order"}}
            local rr,rr_err=c:responses(rb,options)
            local outputs={}
            for _,item in ipairs(rr and rr.data.output or {}) do
                if item.type=="function_call" then
                    required(llm.tools.decode_arguments(item))
                    outputs[#outputs+1]={call_id=item.call_id,output='{"status":"paid"}'}
                end
            end
            record("responses_tools",#outputs>0,rr_err,{model=model})
            if #outputs>0 then
                local continuation,continuation_err=llm.tools.continue_responses(rb,rr,outputs,{mode="replay"})
                if not continuation and continuation_err and continuation_err.code=="unsupported_continuation" then
                    incompatible("responses_tool_continuation",continuation_err,"provider_reasoning_not_replayable",model)
                elseif continuation then
                    continuation.tool_choice="none"
                    local final,final_err=c:responses(continuation,options)
                    record("responses_tool_continuation",final,final_err,{model=model})
                else
                    record("responses_tool_continuation",nil,continuation_err,{model=model})
                end
            end
        end
        required(llm.stop())
    end)
    if not ok then checks[#checks+1]={name="test_harness",status="FAIL",code="harness_failed"} end
    local passed=true
    for _,check in ipairs(checks) do if check.status~="PASS" then passed=false end end
    local result={passed=passed,checks=llm.json.array(checks)}
    local file=assert(io.open("/results/real.json","w")); file:write(llm.json.encode(result)); file:close()
    local marker=assert(io.open("/tmp/skynet-llm-result","w")); marker:write(passed and "PASS\n" or "FAIL\n"); marker:close()
    if not ok then skynet.error("FAIL: real test harness; details withheld to avoid credential output") end
    require("skynet.core").command("ABORT")
end)
