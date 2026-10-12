local skynet=require "skynet"
local llm=require "skynet_llm"
return function(fn)
    skynet.start(function()
        local ok,err=pcall(function()
            assert(llm.start{profiles={main={
                base_url=assert(os.getenv("LLM_BASE_URL"),"LLM_BASE_URL required"),api_key_env="LLM_API_KEY",
                allow_http=os.getenv("LLM_EXAMPLE_ALLOW_HTTP")=="1",
                capabilities={chat=true,chat_stream=true,responses=true,responses_stream=true,embeddings=true,function_tools=true},
            }}})
            fn(assert(llm.client("main")),llm,assert(os.getenv("LLM_MODEL"),"LLM_MODEL required"))
            assert(llm.stop())
        end)
        skynet.error(ok and "PASS: example" or "FAIL: example (check profile and endpoint capabilities)")
        local f=assert(io.open("/tmp/skynet-llm-result","w"));f:write(ok and "PASS\n" or "FAIL\n");f:close()
        require("skynet.core").command("ABORT")
    end)
end
