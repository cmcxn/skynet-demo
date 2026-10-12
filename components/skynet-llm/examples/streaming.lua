require("examples.common")(function(client,llm,model)
    local stream=assert(client:chat_stream{model=model,messages=llm.json.array{{role="user",content="Say hello."}}})
    while true do
        local event,err=stream:next(); assert(not err,err and err.code)
        if not event then break end
        for _,choice in ipairs(event.data.choices or {}) do
            if choice.delta and choice.delta.content then io.write(choice.delta.content) end
        end
    end
    assert(stream:result())
end)
