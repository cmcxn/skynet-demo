-- Exercise the official example server using its sproto protocol.
package.cpath = "tests/?.so;luaclib/?.so"
package.path = "lualib/?.lua;examples/?.lua"
local socket = require "client.socket"
local sproto = require "sproto"
local proto = require "proto"
local host = sproto.new(proto.s2c):host "package"
local request = host:attach(sproto.new(proto.c2s))
local fd = assert(socket.connect("127.0.0.1", 8888), "Demo connection failed")
local buffer = ""

local function send(name, args, session)
    socket.send(fd, string.pack(">s2", request(name, args, session)))
end

local function response(expected)
    -- A bounded wait prevents a broken demo from hanging verification.
    for _ = 1, 1000 do
        while #buffer >= 2 do
            local size = string.unpack(">I2", buffer)
            if #buffer < size + 2 then break end
            local packet = buffer:sub(3, size + 2)
            buffer = buffer:sub(size + 3)
            local kind, session, args = host:dispatch(packet)
            if kind == "RESPONSE" then
                assert(session == expected, "Unexpected response session")
                return args
            end
            assert(kind == "REQUEST" and session == "heartbeat", "Unexpected server request")
        end
        local chunk = socket.recv(fd)
        assert(chunk ~= "", "Server closed connection")
        if chunk then buffer = buffer .. chunk end
        socket.usleep(10000)
    end
    error("Timed out waiting for demo response")
end

send("handshake", nil, 1)
local handshake = response(1)
assert(handshake.msg:find("Welcome to skynet", 1, true), "Handshake failed")
print("PASS: handshake: " .. handshake.msg)
send("set", {what = "docker-demo", value = "hello-from-docker"})
send("get", {what = "docker-demo"}, 2)
local result = response(2)
assert(result.result == "hello-from-docker", "Demo set/get failed")
print("PASS: set/get: " .. result.result)
send("quit")
socket.close(fd)
print("PASS: official Skynet demo round trip")
