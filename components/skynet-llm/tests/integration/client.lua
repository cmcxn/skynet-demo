local skynet = require "skynet"
local llm = require "skynet_llm"

local function check(ok, err)
    assert(ok, err and (err.code .. ": " .. err.message) or "assertion failed")
    return ok
end

skynet.start(function()
    local ok, failure = xpcall(function()
        local caps = {chat=true, responses=true, embeddings=true, chat_stream=true,
            responses_stream=true, function_tools=true}
        skynet.setenv("SKYNET_LLM_TEST_KEY","fixture-secret-key")
        local cfg = {profiles={main={base_url="http://mock:18080/v1", auth="none",
            allow_http=true, capabilities=caps, budget_group="main"},
            secured={base_url="http://mock:18080/v1",api_key_env="SKYNET_LLM_TEST_KEY",
                allow_http=true,capabilities=caps,budget_group="main"},
            malformed={base_url="http://mock:18080/malformed/v1",auth="none",allow_http=true,capabilities=caps},
            small={base_url="http://mock:18080/v1",auth="none",allow_http=true,capabilities=caps,limits={max_request_bytes=128}}},
            budgets={main={max_inflight=4,max_queue=64}}}
        check(llm.start(cfg))
        check(llm.start(cfg))
        local changed = llm.json.decode(llm.json.encode(cfg))
        changed.budgets.main.max_queue = 63
        local started, err = llm.start(changed)
        assert(not started and err.code == "already_started")
        local missing, missing_err = llm.client("missing")
        assert(not missing and missing_err.code == "unknown_profile")
        local c = check(llm.client("main"))
        local body = {model="mock", messages=llm.json.array{{role="user",content="hello"}},
            vendor_extension={empty=llm.json.array{},nullable=llm.json.null}}
        local result, call_err = c:chat(body, {timeout_ms=3000,request_id="client-native",
            connect_timeout_ms=1000,idle_timeout_ms=1000,queue_timeout_ms=2000,priority=3,
            retry={max_attempts=2,base_delay_ms=1,max_delay_ms=2,allow_ambiguous=false}})
        check(result, call_err)
        assert(result.data.choices[1].message.content == "hello")
        assert(result.raw_json and result.meta.attempts == 1)
        assert(result.meta.request_id == "client-native")
        assert(body.stream == nil, "facade changed caller's request")
        local secured=check(llm.client("secured"))
        local denied,denied_err=secured:chat({model="echo-auth-error",messages=body.messages})
        assert(not denied and denied_err.code=="http_error" and denied_err.http_status==401)
        assert(denied_err.attempts==1 and denied_err.provider_error)
        assert(not llm.json.encode(denied_err):find("fixture-secret-key",1,true),"provider error leaked credential")
        local malformed=check(llm.client("malformed"))
        local bad_json,bad_json_err=malformed:chat(body)
        assert(not bad_json and bad_json_err.code=="invalid_json" and bad_json_err.attempts==1)
        local small=check(llm.client("small"))
        local oversized,oversized_err=small:chat({model="mock",messages=llm.json.array{{role="user",content=string.rep("a",1000)}}})
        assert(not oversized and oversized_err.code=="invalid_request")
        assert(llm.stats().groups.small.pending_bytes==0)
        local res, res_err = c:responses({model="mock",input="hello"})
        check(res, res_err)
        assert(llm.responses.output_text(res) == "hello")
        local emb, emb_err = c:embeddings({model="mock",input=llm.json.array{"a","b"}},
            {expected_dimensions=3})
        check(emb, emb_err)
        assert(#llm.embeddings.vectors(emb) == 2)
        local invalid, invalid_err = c:chat(body, {timeout_ms=0})
        assert(not invalid and invalid_err.code == "invalid_request")
        for _,tool in ipairs{42,true} do
            local accepted,malformed_tool,tool_err=pcall(c.chat,c,{model="mock",messages=body.messages,tools=llm.json.array{tool}})
            assert(accepted and not malformed_tool and tool_err.code=="invalid_request","malformed tools escaped nil,error contract")
        end
        local bad_config, bad_config_err = llm.start{profiles={bad={base_url="http://user:pass@mock/v1",auth="none"}}}
        assert(not bad_config and bad_config_err.code == "already_started")
        local state, state_err = c:responses({model="mock",input="hello",store=true})
        assert(not state and state_err.code == "unsupported_capability")
        local background, background_err = c:responses({model="mock",input="hello",background=true})
        assert(not background and background_err.code == "unsupported_capability")
        local stream, stream_err = c:chat_stream(body)
        check(stream, stream_err)
        local count = 0
        while true do
            local event, event_err = stream:next()
            assert(not event_err, event_err and event_err.message)
            if not event then break end
            assert(event.kind == "chat.chunk" and type(event.raw_data) == "string")
            count = count + 1
        end
        assert(count > 0)
        local assembled, assembled_err = stream:result()
        check(assembled, assembled_err)
        assert(assembled.data.choices[1].message.content == "hello")
        assert(assembled.meta.assembled and assembled.raw_json == nil)
        assert(stream:result() == assembled, "result must be retained in facade")
        check(stream:cancel())
        assert(stream:result() == assembled)
        local responses_stream = check(c:responses_stream({model="mock",input="hello"}))
        local assembled_res, assembled_res_err = responses_stream:result()
        check(assembled_res, assembled_res_err)
        assert(llm.responses.output_text(assembled_res) == "hello")
        local stats = check(llm.stats())
        assert(stats.groups.main.inflight == 0 and stats.groups.main.pending_streams == 0)
        check(llm.stop())
        local stopped, stopped_err = c:chat(body)
        assert(not stopped and stopped_err.code == "not_started")
        skynet.error("PASS: client native APIs, typed snapshots, streams and lifecycle")
    end, debug.traceback)
    local f = assert(io.open("/tmp/skynet-llm-result", "w"))
    f:write(ok and "PASS\n" or "FAIL\n" .. tostring(failure)); f:close()
    if not ok then skynet.error(failure) end
    require("skynet.core").command("ABORT")
end)
