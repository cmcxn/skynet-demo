local skynet = require "skynet"
skynet.start(function()
    local ok, err = xpcall(function()
        assert(_VERSION == "Lua 5.5")
        for _, name in ipairs {"ltls.c", "pgmoon", "pgvector", "skynet_llm", "skynet_llm_tls", "skynet_postgres_native"} do
            assert(require(name))
            skynet.error("PASS: service load " .. name)
        end
        local driver = require "skynet.socketdriver"
        assert(type(driver.connect_read_limit) == "function")
        assert(type(driver.start_read_limit) == "function")
        assert(type(require("skynet.socket").start_read_limit) == "function")
        local path = assert(package.searchpath("pgmoon", package.path))
        assert(path:find("/skynet/lualib/", 1, true), path)
    end, debug.traceback)
    local file = assert(io.open("/tmp/skynet-runtime-load-result", "w"))
    file:write(ok and "PASS" or "FAIL")
    file:close()
    if not ok then skynet.error(err) end
    require("skynet.core").command("ABORT")
end)
