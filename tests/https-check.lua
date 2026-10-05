local skynet = require "skynet"

-- A separate test process: exiting must never stop the running demo server.
skynet.start(function()
    local httpc = require "http.httpc"
    local cjson = require "cjson"
    httpc.timeout = 3000 -- Skynet ticks are 10 ms: 30 seconds per request.
    local checks = {
        {name = "Baidu HTTPS", run = function()
            local status, body = httpc.get("https://www.baidu.com", "/")
            assert(status == 200, "expected HTTP 200, got " .. tostring(status))
            assert(type(body) == "string" and #body > 0, "empty response body")
            print("PASS: Baidu HTTPS status=200 bytes=" .. #body)
        end},
        {name = "httpbin HTTPS JSON", run = function()
            local status, body = httpc.get("https://httpbin.org", "/ip", nil, {Accept = "application/json"})
            assert(status == 200, "expected HTTP 200, got " .. tostring(status))
            local decoded = cjson.decode(body)
            assert(type(decoded) == "table" and type(decoded.origin) == "string"
                and decoded.origin:match("%S"), "JSON origin must be a nonempty string")
            print("PASS: httpbin HTTPS JSON status=200 origin=" .. decoded.origin)
        end},
    }
    local passed = true
    for _, check in ipairs(checks) do
        local ok, err = xpcall(check.run, debug.traceback)
        if not ok then
            passed = false
            io.stderr:write("FAIL: " .. check.name .. "\n" .. tostring(err) .. "\n")
            io.stderr:flush()
        end
        io.stdout:flush()
    end
    -- Terminate only this short-lived test process. ABORT can hang on Windows.
    os.exit(passed and 0 or 1)
end)
