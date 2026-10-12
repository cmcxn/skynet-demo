require("examples.common")(function(client,llm,model)
    local body={model=model,messages=llm.json.array{{role="user",content="Query order A123 using get_order."}},
        tools=llm.json.array{{type="function",["function"]={name="get_order",parameters={type="object",
            properties={order_id={type="string"}},required=llm.json.array{"order_id"},additionalProperties=false},strict=true}}}}
    local res,err=client:chat(body); assert(res,err and err.code)
    local results={}
    for _,call in ipairs(res.data.choices[1].message.tool_calls or {}) do
        local args=assert(llm.tools.decode_arguments(call))
        assert(call["function"].name=="get_order" and args.order_id=="A123")
        -- Business executes its authorized tool here.
        results[#results+1]={tool_call_id=call.id,output='{"status":"paid"}'}
    end
    if #results>0 then
        local next_body=assert(llm.tools.continue_chat(body,res,results))
        assert(client:chat(next_body))
    end
end)
