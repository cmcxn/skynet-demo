local skynet = require "skynet"
skynet.start(function()
    local ok, err = xpcall(function()
        local cjson = require "cjson"
        local decoded = cjson.decode(cjson.encode({message="你好", value=42, enabled=true}))
        assert(decoded.message == "你好" and decoded.value == 42 and decoded.enabled == true)
        assert(not pcall(cjson.decode, "{broken"))
        skynet.error("PASS: cjson round trip and invalid JSON rejection")
        assert(require "ltls.c")
        local httpc = require "http.httpc"
        httpc.timeout = 3000
        local status, body = httpc.get("https://www.baidu.com", "/")
        assert(status == 200 and #body > 0, "HTTPS request failed: " .. tostring(status))
        skynet.error("PASS: HTTPS status=" .. status .. " bytes=" .. #body)
        local ip_status, ip_body = httpc.get("https://httpbin.org", "/ip", nil, {Accept="application/json"})
        assert(ip_status == 200, "httpbin HTTPS request failed: " .. tostring(ip_status))
        local ip = cjson.decode(ip_body)
        assert(type(ip) == "table" and type(ip.origin) == "string" and ip.origin:match("%S"),
            "httpbin JSON origin must be a nonempty string")
        skynet.error("PASS: httpbin HTTPS JSON origin=" .. ip.origin)
    end, debug.traceback)
    local result = assert(io.open("/tmp/skynet-features-result", "w"))
    result:write(ok and "PASS\n" or "FAIL\n" .. tostring(err))
    result:close()
    if not ok then skynet.error(err) end
    require("skynet.core").command("ABORT")
end)
