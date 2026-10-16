local skynet = require "skynet"
skynet.start(function()
    local ok, err = xpcall(function()
        local count = dofile(skynet.getenv("aoi_test_dir") .. "/unit.lua")
        assert(count >= 23)
        skynet.error("PASS: real Skynet service loaded aoi.so and passed " .. count .. " AOI tests")
    end, debug.traceback)
    local result = assert(io.open(skynet.getenv("aoi_test_result"), "w"))
    result:write(ok and "PASS\n" or "FAIL\n" .. tostring(err))
    result:close()
    if not ok then skynet.error(err) end
    require("skynet.core").command("ABORT")
end)
