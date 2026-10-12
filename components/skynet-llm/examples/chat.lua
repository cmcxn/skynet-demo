require("examples.common")(function(client,llm,model)
    local result,err=client:chat{model=model,messages=llm.json.array{{role="user",content="Say hello."}}}
    assert(result,err and err.code)
    print(result.data.choices[1].message.content)
end)
