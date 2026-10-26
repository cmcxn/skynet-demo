-- Experimental loader: lua-http compatibility is private to upstream modules.
local httpc = require 'http.httpc'
local M = {}
function M.load(source)
    local cache = {}
    local request = {}
    function request.new_from_uri(url)
        local origin, path = url:match('^(https?://[^/]+)(/.*)$')
        assert(origin, 'expected absolute HTTP URL with path')
        local values = {}
        local r = {headers = {}}
        function r.headers:upsert(k, v) values[k] = v end
        function r:set_body(body) self.body = body end
        function r:go()
            local headers = {}
            for k,v in pairs(values) do if k:sub(1,1) ~= ':' then headers[k] = v end end
            local status, body = httpc.request(values[':method'] or 'GET', origin, path, {}, headers, self.body)
            return {get = function(_, k) if k == ':status' then return tostring(status) end end},
                {get_body_as_string = function() return body end}
        end
        return r
    end
    -- Matches encodeURI, preserving URI delimiters. Upstream filter values
    -- containing '&'/'#' still need attention; this is not encodeURIComponent.
    local util = {encodeURI = function(url)
        return (url:gsub("[^%w%-_%.!~*'();/?:@&=+$,#]", function(c)
            return string.format('%%%02X', c:byte())
        end))
    end}
    local function upstream(name)
        if name == 'http.request' then return request end
        if name == 'http.util' then return util end
        if name:sub(1,10) ~= 'postgrest.' then return require(name) end
        if not cache[name] then
            local env = setmetatable({require = upstream}, {__index = _G})
            cache[name] = assert(loadfile(source .. '/' .. name:gsub('%.','/') .. '.lua', 't', env))()
        end
        return cache[name]
    end
    return upstream('postgrest.database')
end
return M
