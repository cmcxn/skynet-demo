package.path = "lualib/?.lua;examples/?.lua"
package.cpath = "luaclib/?.so"

local cjson = require "cjson"
local decoded = cjson.decode(cjson.encode({message="你好", value=42, enabled=true}))
assert(decoded.message == "你好" and decoded.value == 42 and decoded.enabled)
assert(not pcall(cjson.decode, "{broken"))
assert(require "sproto.core")
assert(require "lpeg")
print("PASS: JSON round trip and native module loading")

local init = require "ltls.init.c"
init.constructor()
local tls = require "ltls.c"
local ctx = tls.newctx()
local conn = tls.newtls("client", ctx, "localhost")
assert(#conn:handshake() > 0, "TLS ClientHello was not generated")
conn:close()
conn, ctx = nil, nil
collectgarbage("collect")
init.destructor()
print("PASS: TLS initialization and ClientHello generation")
