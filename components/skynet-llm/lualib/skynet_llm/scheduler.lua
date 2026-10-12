local M={}

function M.priority(request, now)
    return math.min(3,request.options.priority+math.floor((now-request.queued_at)/100))
end

function M.pop(queue, now)
    local best,priority
    for i,r in ipairs(queue) do
        if not r.terminal and (not r.ready_at or r.ready_at<=now) then
            local p=M.priority(r,now)
            if not best or p>priority or (p==priority and r.order<queue[best].order) then best=i; priority=p end
        end
    end
    if best then return table.remove(queue,best) end
end

function M.remove(queue, request)
    for i,r in ipairs(queue) do if r==request then table.remove(queue,i); return true end end
end

return M
