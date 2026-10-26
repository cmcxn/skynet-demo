-- Environment-neutral initialization. Call once during service startup.
local adapter = require 'skynet_postgrest'
local httpc = require 'http.httpc'
local M = {}
function M.new(source)
    local url = assert(os.getenv('DB_REST_URL'), 'DB_REST_URL is required')
    assert(url:match('^https?://[^/]+'), 'DB_REST_URL must be an absolute HTTP(S) URL')
    assert(not url:find('[?#]'), 'DB_REST_URL must not contain a query or fragment')
    local timeout = tonumber(os.getenv('DB_TIMEOUT_TICKS') or '3000')
    assert(timeout and timeout > 0 and timeout % 1 == 0 and timeout < math.huge,
        'DB_TIMEOUT_TICKS must be a positive integer')
    local token = os.getenv('DB_REST_TOKEN') or ''
    assert(not token:find('[\r\n]'), 'DB_REST_TOKEN must not contain newlines')
    local headers = {Prefer='return=representation'}
    if token ~= '' then headers.Authorization = 'Bearer ' .. token end
    httpc.timeout = timeout
    httpc.proxy = false
    return adapter.load(source):new(url:gsub('/+$',''), headers)
end
return M
