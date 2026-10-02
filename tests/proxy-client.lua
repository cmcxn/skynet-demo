-- Test driver only: real http.httpc requests against loopback fixtures.
local skynet = require "skynet"
local httpc = require "http.httpc"
local socket = require "skynet.socket"
local case = assert(loadfile(assert(os.getenv("PROXY_CASE_FILE"))))()

local function one(request)
    httpc.timeout = request.timeout or 150
    httpc.cafile = request.cafile
    httpc.capath = request.capath
    httpc.proxy = request.proxy
    if request.dns_server then httpc.dns(request.dns_server, request.dns_port) end
    local headers = request.headers
    local received = {}
    local start = skynet.now()
    local ok, value = pcall(function()
        if request.method == "HEAD" then
            local status = httpc.head(request.host, request.path, received, headers)
            assert(status == 200, "unexpected HEAD status: " .. tostring(status))
            assert(received["x-origin"] == "loopback", "HEAD lost response headers")
            return ""
        elseif request.method == "STREAM" then
            local before = {}
            if request.idle_wait then
                for _, info in ipairs(socket.netstat()) do before[info.id] = true end
            end
            local stream = httpc.request_stream("GET", request.host, request.path, received, headers)
            assert(stream.status == 200, "unexpected stream status")
            if request.idle_wait then
                local ids = {}
                for _, info in ipairs(socket.netstat()) do
                    if not before[info.id] and info.address == skynet.self() and info.type == "TCP" then
                        ids[#ids + 1] = info.id
                    end
                end
                assert(#ids == 1, "could not identify the idle stream socket")
                -- No read or explicit close wakes cleanup during this interval.
                skynet.sleep(request.idle_wait)
                for _, id in ipairs(ids) do
                    assert(socket.invalid(id), "idle stream timeout retained socket in Lua socket pool")
                end
                httpc.proxy = false
                httpc.timeout = 100
                local status, body = httpc.get(case.audit_host, "/audit")
                assert(status == 200 and body == "0", "idle stream TCP socket still open: " .. tostring(body))
                stream:close()
                stream:close()
                return ""
            end
            if request.close_early then
                stream:close()
                stream:close() -- explicit close must remain idempotent
                return ""
            end
            local pieces = {}
            -- Deliberately do not auto-close on an error: httpc owns error cleanup.
            for piece in stream do
                pieces[#pieces + 1] = piece
            end
            stream:close()
            return table.concat(pieces)
        else
            local status, body = httpc.get(request.host, request.path, received, headers)
            assert(status == 200, "unexpected status: " .. tostring(status))
            return body
        end
    end)
    local elapsed = (skynet.now() - start) / 100
    if request.fail then
        assert(not ok, request.name .. ": request unexpectedly succeeded")
        local err = tostring(value)
        for _, secret in ipairs({"u@ser", "p:ss", "u%40ser", "p%3Ass", "dUBzZXI6cDpzcw=="}) do
            assert(not err:find(secret, 1, true), "proxy credentials leaked in error")
        end
        if request.error_contains then
            assert(err:find(request.error_contains, 1, true), "unexpected error: " .. err)
        end
    else
        assert(ok, request.name .. ": " .. tostring(value))
        if request.body then
            assert(value == request.body, request.name .. ": unexpected response body " .. tostring(value))
        end
    end
    if request.min_seconds then
        assert(elapsed >= request.min_seconds, request.name .. ": failed before the intended timeout (" .. elapsed .. "s)")
    end
    if request.max_seconds then
        assert(elapsed <= request.max_seconds, request.name .. ": timeout was not enforced (" .. elapsed .. "s)")
    end
    if headers then
        assert(headers["pRoXy-AuThOrIzAtIoN"] == request.original_proxy_authorization,
            "request mutated caller-owned Proxy-Authorization header")
    end
    skynet.error("PASS: " .. request.name)
end

skynet.start(function()
    local ok, err = xpcall(function()
        for _, request in ipairs(case.requests) do one(request) end
        -- Audit while this process is still alive. Exit must not mask open fds.
        httpc.proxy = false
        httpc.cafile = nil
        httpc.capath = nil
        httpc.timeout = 100
        skynet.sleep(25)
        local status, body = httpc.get(case.audit_host, "/audit")
        assert(status == 200 and body == "0", "sockets still open before process exit: " .. tostring(body))
    end, debug.traceback)
    local result = assert(io.open(assert(os.getenv("PROXY_RESULT_FILE")), "w"))
    result:write(ok and "PASS\n" or "FAIL\n" .. tostring(err) .. "\n")
    result:close()
    if not ok then skynet.error(err) end
    require("skynet.core").command("ABORT")
end)
