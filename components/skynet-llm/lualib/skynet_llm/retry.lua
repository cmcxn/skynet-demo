local M={}
local months={Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}

function M.retry_after(value, now)
    if type(value)~="string" then return nil end
    if value:match("^%s*%d+%s*$") then return tonumber(value)*1000 end
    local d,m,y,h,min,s=value:match("^%a%a%a, (%d%d) (%a%a%a) (%d%d%d%d) (%d%d):(%d%d):(%d%d) GMT$")
    m=months[m]; if not m then return nil end
    d,y,h,min,s=tonumber(d),tonumber(y),tonumber(h),tonumber(min),tonumber(s)
    if d<1 or d>31 or h>23 or min>59 or s>59 then return nil end
    -- Gregorian civil date to UTC days, independent of the worker's timezone.
    y=y-(m<=2 and 1 or 0)
    local era=math.floor(y/400); local yoe=y-era*400
    local doy=math.floor((153*(m+(m>2 and -3 or 9))+2)/5)+d-1
    local days=era*146097+yoe*365+math.floor(yoe/4)-math.floor(yoe/100)+doy-719468
    return math.max(0,(days*86400+h*3600+min*60+s-now)*1000)
end

function M.delay(err, attempts, policy, remaining_ms, delivered, random, now)
    if delivered or attempts>=policy.max_attempts then return nil end
    local eligible=false
    if err.http_status then
        local status=err.http_status
        eligible=status==429 or status==502 or status==503 or status==504
        for _,v in pairs(policy.statuses or {}) do if status==v then eligible=true end end
    elseif err.code=="tls_error" or err.code=="invalid_json" or err.code=="invalid_response" or err.code=="cancelled" then return nil
    elseif not err.may_have_executed then eligible=err.retryable==true
    elseif policy.allow_ambiguous then eligible=err.code=="timeout" or err.code=="stream_interrupted" or err.code=="network_error" end
    if not eligible then return nil end
    local cap=math.min(policy.max_delay_ms,policy.base_delay_ms*2^(attempts-1))
    local delay=math.floor((random or math.random)()*cap)
    delay=math.max(delay,M.retry_after(err.retry_after,now or os.time()) or 0)
    if delay>=remaining_ms then return nil end
    return delay
end

return M
