local skynet = require "skynet"

-- Windows console handles cannot be polled as POSIX stdin sockets.
-- Use client.bat or the TCP debug console for interactive access.
skynet.start(function()
    skynet.error("Server start")
    skynet.uniqueservice("protoloader")
    skynet.newservice("debug_console", 8000)
    skynet.newservice("simpledb")
    local watchdog = skynet.newservice("watchdog")
    local addr, port = skynet.call(watchdog, "lua", "start", {
        port = 8888,
        maxclient = 64,
        nodelay = true,
    })
    skynet.error("Watchdog listen on " .. addr .. ":" .. port)
    skynet.exit()
end)
