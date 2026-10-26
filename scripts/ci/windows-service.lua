local skynet = require "skynet"
skynet.start(function()
    local ok, err = xpcall(function()
        assert(_VERSION == "Lua 5.5")
        for _, name in ipairs {"ltls.c", "pgmoon", "pgvector", "skynet_llm", "skynet_llm_tls", "skynet_postgres_native", "skynet_aoi", "skynet_postgrest", "skynet_postgrest_client"} do
            assert(require(name))
            skynet.error("PASS: Windows service load " .. name)
        end
        assert(type(require("skynet_postgrest").load().new) == "function")
        assert(type(require("skynet.socketdriver").connect_read_limit) == "function")
        assert(type(require("skynet.socket").start_read_limit) == "function")
    end, debug.traceback)
    local f = assert(io.open("ci-service-result.txt", "w"))
    f:write(ok and "PASS" or "FAIL"); f:close()
    if not ok then skynet.error(err) end
    -- The portable Windows harness uses process exit (see windows/compile.sh).
    -- Graceful ABORT shutdown is not a supported assertion of this package test.
    os.exit(ok and 0 or 1)
end)
