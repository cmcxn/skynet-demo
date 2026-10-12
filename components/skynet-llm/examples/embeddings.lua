require("examples.common")(function(client,llm,model)
    local res,err=client:embeddings{model=model,input=llm.json.array{"first text","second text"}}
    assert(res,err and err.code)
    local vectors=assert(llm.embeddings.vectors(res))
    print("vectors="..#vectors.." dimensions="..#vectors[1])
end)
