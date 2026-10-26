local skynet = require 'skynet'
local client = require 'skynet_postgrest_client'
skynet.start(function()
    local token = os.getenv('DB_REST_TOKEN') or ''
    local db, count = nil, 0
    local name = 'skynet_postgrest_test_20261026'
    local id = assert(os.getenv('DB_TEST_RUN_ID'))
    local function test(label, fn)
        fn(); count = count + 1; print('PASS ' .. label)
    end
    local ok, err = xpcall(function()
        db = client.new()
        test('insert UTF-8 JSON and representation', function()
            local rows = db:from(name):insert{id=id,task='学习 Lua 空格',done=false}:execute()
            assert(#rows==1 and rows[1].id==id)
        end)
        test('select columns and filter', function()
            local rows = db:from(name):select('id','task','done'):filter{id=id}:execute()
            assert(#rows==1 and rows[1].task=='学习 Lua 空格' and rows[1].done==false)
        end)
        test('UTF-8 string URI encoding', function()
            assert(#db:from(name):select():filter{id=id,task='学习 Lua 空格'}:execute()==1)
        end)
        test('update and representation', function()
            local rows = db:from(name):update{done=true}:filter{id=id}:execute()
            assert(#rows==1 and rows[1].done==true)
        end)
        test('operator filter', function()
            assert(#db:from(name):select():filter{id=id,done__is=true}:execute()==1)
        end)
        test('HTTP errors propagate', function()
            local success, message = pcall(function() db:from(name):select('column_that_does_not_exist'):filter{id=id}:execute() end)
            assert(not success and tostring(message):find('400',1,true))
        end)
        test('delete and representation', function()
            local rows = db:from(name):delete():filter{id=id}:execute()
            assert(#rows==1 and rows[1].id==id)
        end)
        test('empty after delete', function()
            assert(#db:from(name):select():filter{id=id}:execute()==0)
        end)
        assert(package.loaded['http.request']==nil, 'global module pollution')
    end, debug.traceback)
    if not ok then
        if db then
            local cleaned = pcall(function() db:from(name):delete():filter{id=id}:execute() end)
            if not cleaned then skynet.error('Cleanup failed for test record ' .. id) end
        end
        local message = tostring(err)
        if token ~= '' then message = message:gsub(token:gsub('([^%w])','%%%1'),'[redacted]') end
        io.stderr:write(message, '\n'); io.stderr:flush(); os.exit(1)
    end
    print('PASS: ' .. count .. ' shared PostgREST integration groups')
    os.exit(0)
end)
