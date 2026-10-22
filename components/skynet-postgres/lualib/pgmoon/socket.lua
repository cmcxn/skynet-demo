-- Skynet transport: one owner per operation, verified TLS and total deadlines.
local skynet = require 'skynet'
local socket = require 'skynet.socket'
local driver = require 'skynet.socketdriver'
local dns = require 'skynet.dns'
local flatten = require('pgmoon.util').flatten
local native = require 'skynet_postgres_native'
local methods = {}
local dns_initialized = false
local function initialize_dns()
  if dns_initialized then return end
  local override = os.getenv('SKYNET_POSTGRES_DNS_SERVER')
  if override then
    local address, port = override:match('^(%d+%.%d+%.%d+%.%d+):(%d+)$')
    address, port = address or override, tonumber(port or 53)
    local a,b,c,d = address:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
    assert(a and tonumber(a)<=255 and tonumber(b)<=255 and tonumber(c)<=255 and tonumber(d)<=255 and port>=1 and port<=65535,
      'SKYNET_POSTGRES_DNS_SERVER must be IPv4[:port]')
    dns.server(address, port)
  elseif package.config:sub(1,1) == '\\' then
    dns.server(assert(native.system_dns_server()))
  end
  dns_initialized = true
end

function methods:settimeout(ms)
  assert(type(ms) == 'number' and ms > 0 and ms < math.huge and ms % 1 == 0,
    'timeout must be a positive integer in milliseconds')
  assert(not self.operation, 'cannot change timeout during an operation')
  self.timeout = ms
  return true
end

function methods:close()
  local fd = self.fd
  self.fd = nil
  if self.session then self.session:close(); self.session = nil end
  if self.context then self.context:close(); self.context = nil end
  self.buffer = ''
  if fd then
    if socket.invalid(fd) then driver.close(fd) else socket.close(fd) end
  end
  return true
end

function methods:check()
  local op = self.operation
  if op and (op.expired or skynet.now() >= op.deadline) then error('PostgreSQL operation timeout', 0) end
end

function methods:run(fn, ...)
  if self.operation then return nil, 'PostgreSQL connection is busy' end
  local op = {deadline = skynet.now() + math.max(1, math.ceil(self.timeout / 10))}
  self.operation = op
  skynet.timeout(math.max(1, math.ceil(self.timeout / 10)), function()
    if self.operation == op then
      op.expired = true
      if self.fd then socket.shutdown(self.fd) end
      if op.dns_wait then skynet.wakeup(op.dns_wait) end
    end
  end)
  local result = table.pack(pcall(fn, ...))
  local expired = op.expired or skynet.now() >= op.deadline
  self.operation = nil
  if not result[1] or expired then
    pcall(self.close, self)
    return nil, expired and 'PostgreSQL operation timeout' or tostring(result[2])
  end
  return table.unpack(result, 2, result.n)
end

function methods:connect(host, port)
  assert(not self.fd, 'PostgreSQL socket is already connected')
  self:check()
  local address = host
  if not host:find(':',1,true) and not host:match('^%d+%.%d+%.%d+%.%d+$') then
    initialize_dns()
    local op = assert(self.operation)
    local done, ok, answer
    local owner = coroutine.running()
    op.dns_wait = owner
    skynet.fork(function()
      ok, answer = pcall(dns.resolve, host)
      done = true
      if op.dns_wait then skynet.wakeup(owner) end
    end)
    skynet.sleep(math.max(1, op.deadline - skynet.now()))
    op.dns_wait = nil
    self:check()
    assert(done and ok, 'PostgreSQL DNS resolution failed')
    address = answer
  end
  self.fd = assert(driver.connect(address, tonumber(port)), 'PostgreSQL connect failed')
  local fd, err = socket.start(self.fd)
  self:check()
  assert(fd, err or 'PostgreSQL connect failed')
  socket.limit(fd, self.config.max_message_bytes or 16777216)
  return true
end

function methods:_raw_read(n)
  self:check()
  local value = socket.read(assert(self.fd, 'PostgreSQL socket is closed'), n)
  self:check()
  assert(value, 'PostgreSQL connection closed during read')
  return value
end
function methods:_raw_write(data)
  self:check()
  assert(socket.write(assert(self.fd, 'PostgreSQL socket is closed'), data), 'PostgreSQL write failed')
  self:check()
end
function methods:_drain()
  local bytes, err = self.session:drain()
  assert(bytes, err)
  if #bytes > 0 then self:_raw_write(bytes) end
end
function methods:_feed()
  local ok, err = self.session:feed(self:_raw_read())
  assert(ok, err)
end

function methods:sslhandshake()
  local cfg = self.config
  local cafile, capath = cfg.cafile, cfg.capath
  -- The portable package is launched from its root; preserve explicit env overrides.
  if not cafile and not capath and package.config:sub(1,1) == '\\' and not os.getenv('SSL_CERT_FILE') and not os.getenv('SSL_CERT_DIR') then
    cafile = 'certs/ca-bundle.crt'
  end
  self.context = assert(native.context {ca_file=cafile, ca_path=capath,
    use_default_ca=not (cafile or capath)})
  self.session = assert(native.session(self.context, cfg.ssl_server_name or cfg.host))
  while true do
    self:check()
    local state, err = self.session:handshake()
    self:_drain()
    assert(state, err)
    if state == 'ok' then return true end
    assert(state ~= 'close_notify', 'PostgreSQL TLS closed during handshake')
    if state == 'want_read' then self:_feed() end
  end
end

function methods:send(data)
  data = flatten(data)
  if not self.session then self:_raw_write(data); return #data end
  local offset = 1
  while offset <= #data do
    local count, state = self.session:write(data:sub(offset, offset+16383))
    self:_drain()
    assert(count, state)
    assert(state ~= 'close_notify', 'PostgreSQL TLS closed during write')
    offset = offset + count
    if state == 'want_read' then self:_feed() end
  end
  return #data
end
function methods:receive(n)
  assert(type(n)=='number' and n>=0 and n%1==0 and n <= (self.config.max_message_bytes or 16777216),
    'invalid PostgreSQL message size')
  if n == 0 then return '' end
  if not self.session then return self:_raw_read(n) end
  while #self.buffer < n do
    local bytes, state = self.session:read()
    assert(bytes, state)
    self:_drain()
    self.buffer = self.buffer .. bytes
    assert(state ~= 'close_notify', 'PostgreSQL TLS connection closed')
    if state == 'want_read' then self:_feed() end
  end
  local result = self.buffer:sub(1,n)
  self.buffer = self.buffer:sub(n+1)
  return result
end
function methods:getreusedtimes() return 0 end
function methods:setkeepalive() return nil, 'use an application-owned connection; no nginx pool' end

return {
  new = function(kind, config)
    assert(kind == nil or kind == 'skynet', 'only socket_type=skynet is supported')
    assert(config.ssl_verify ~= false, 'disabling PostgreSQL TLS verification is not supported')
    assert(config.ssl == true or config.ssl == false, 'ssl must be a boolean')
    assert(not config.cert and not config.key and not config.luasec_opts and not config.cqueues_openssl_context and not config.ssl_version,
      'client certificates and backend-specific TLS options are not supported')
    local limit = config.max_message_bytes or 16777216
    assert(type(limit)=='number' and limit >= 5 and limit <= 2147483647 and limit % 1 == 0,
      'max_message_bytes must be an integer from 5 to 2147483647')
    local s = setmetatable({config=config, buffer=''}, {__index=methods})
    s:settimeout(config.timeout or 30000)
    return s, 'skynet'
  end,
}
