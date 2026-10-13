package.path = "lualib/?.lua;" .. package.path
package.cpath = "luaclib/?.so;" .. package.cpath

local tls = require "skynet_llm_tls"
local ctx, err = tls.context{ca_file="certs/ca-bundle.crt",use_default_ca=false}
assert(ctx, err)
for _, host in ipairs{"example.com", "127.0.0.1", "::1"} do
    local session = assert(tls.session(ctx, host))
    assert(session:handshake() == "want_read")
    assert(#session:drain() > 0, "missing TLS ClientHello")
    session:close()
    session:close()
end
ctx:close()
local missing = tls.context{ca_file="certs/does-not-exist.pem",use_default_ca=false}
assert(not missing, "missing CA must fail closed")
collectgarbage("collect")
print("PASS: LLM TLS module, CA loading, DNS/IP verification setup and cleanup")
