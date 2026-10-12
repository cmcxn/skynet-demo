require("examples.common")(function(client,llm,model)
    local body={model=model,input="Query order A123 using get_order.",store=false,
        tools=llm.json.array{{type="function",name="get_order",parameters={type="object",
            properties={order_id={type="string"}},required=llm.json.array{"order_id"},additionalProperties=false},strict=true}}}
    local res,err=client:responses(body); assert(res,err and err.code)
    local outputs={}
    for _,item in ipairs(res.data.output) do
        if item.type=="function_call" then
            local args=assert(llm.tools.decode_arguments(item)); assert(args.order_id=="A123")
            outputs[#outputs+1]={call_id=item.call_id,output='{"status":"paid"}'}
        end
    end
    if #outputs>0 then
        local next_body=assert(llm.tools.continue_responses(body,res,outputs,{mode="replay"}))
        assert(client:responses(next_body))
    end
end)
