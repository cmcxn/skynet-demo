-- The I/O adapter supplies read(), write(bytes), and check(stage). It owns
-- socket deadlines/cancellation; this module owns context/session lifetimes.
local M = {}
local Connection = {}
Connection.__index = Connection

local function error_for(message, stage, code)
    return {code = code or 'tls_error', stage = stage or 'tls', message = tostring(message), retryable = false}
end
local function context(profile)
    local loaded, native = pcall(require, 'skynet_llm_tls')
    if not loaded then return nil, error_for('verified TLS extension is unavailable') end
    local config = profile.tls or {ca_file = profile.ca_file, ca_path = profile.ca_path}
    local ok, ctx, err = pcall(native.context, config)
    if not ok then return nil, error_for(ctx) end
    if not ctx then return nil, error_for(err) end
    return ctx, native
end
function M.validate(profile)
    local ctx, err = context(profile)
    if not ctx then return nil, err end
    ctx:close()
    return true
end
function M.new(profile, hostname)
    local ctx, native = context(profile)
    if not ctx then return nil, native end
    local ok, session, err = pcall(native.session, ctx, hostname)
    if not ok or not session then
        ctx:close()
        return nil, error_for(ok and err or session)
    end
    return setmetatable({context = ctx, session = session}, Connection)
end
function Connection:close()
    if self.session then self.session:close(); self.session = nil end
    if self.context then self.context:close(); self.context = nil end
end
local function drain(self, io)
    local bytes, err = self.session:drain()
    if not bytes then return nil, error_for(err) end
    if #bytes > 0 then return io.write(bytes) end
    return true
end
local function input(self, io, stage)
    local bytes, err = io.read(stage)
    if not bytes then
        if err then return nil, err end
        self.session:eof()
        return false
    end
    local ok, feed_err = self.session:feed(bytes)
    if not ok then return nil, error_for(feed_err, stage) end
    return true
end
function Connection:handshake(io)
    while true do
        local ok, err = io.check('tls')
        if not ok then return nil, err end
        local state, operation_err = self.session:handshake()
        ok, err = drain(self, io) -- fatal errors can produce an alert as well.
        if not state then return nil, error_for(operation_err) end
        if not ok then return nil, err end
        if state == 'ok' then return true end
        if state == 'close_notify' then return nil, error_for('peer closed during TLS handshake') end
        if state == 'want_read' then
            ok, err = input(self, io, 'tls')
            if not ok then return nil, err or error_for('EOF during TLS handshake') end
        end
    end
end
function Connection:read(io)
    while true do
        local ok, err = io.check('read')
        if not ok then return nil, err end
        local bytes, state = self.session:read()
        ok, err = drain(self, io)
        if not bytes then return nil, error_for(state, 'read', 'stream_interrupted') end
        if not ok then return nil, err end
        if #bytes > 0 then return bytes end
        if state == 'close_notify' then return nil end
        if state == 'want_read' then
            ok, err = input(self, io, 'read')
            if ok == nil then return nil, err end
            -- On TCP EOF, the next SSL_read distinguishes close_notify from
            -- unexpected EOF. OpenSSL's insecure ignore-EOF flag is never set.
        end
    end
end
function Connection:write(io, bytes)
    local position = 1
    while position <= #bytes do
        local piece = bytes:sub(position, position + 16383)
        local offset = 1
        while offset <= #piece do
            local ok, err = io.check('write')
            if not ok then return nil, err end
            local count, state = self.session:write(piece:sub(offset))
            ok, err = drain(self, io)
            if not count then return nil, error_for(state, 'write') end
            if not ok then return nil, err end
            if state == 'close_notify' then return nil, error_for('peer closed during TLS write', 'write') end
            offset = offset + count
            if state == 'want_read' then
                ok, err = input(self, io, 'write')
                if not ok then return nil, err or error_for('EOF during TLS write', 'write') end
            end
        end
        position = position + #piece
    end
    return true
end

return M
