local skynet = require 'skynet'
local client = require 'skynet_postgrest_client'
local vector = require 'pgvector'
skynet.start(function()
    local db, count = nil, 0
    local token = os.getenv('DB_REST_TOKEN') or ''
    local run = assert(os.getenv('DB_TEST_RUN_ID'))
    local name = 'skynet_pgvector_test_20261026'
    local function eq(a,b) assert(a==b, tostring(a)..' ~= '..tostring(b)) end
    local function near(a,b) assert(math.abs(a-b)<1e-6, tostring(a)..' not near '..tostring(b)) end
    local function test(label, fn) fn(); count=count+1; print('PASS '..label) end
    local function search(metric, limit, test_run, query)
        -- The upstream POST builder also supports the PostgREST rpc/<function> route.
        return db:from('rpc/skynet_pgvector_match_20261026'):insert{
            query_embedding=vector.serialize(query or {0.9,0.1,0}),
            test_run=test_run or run, metric=metric, match_count=limit or 3,
        }:execute()
    end
    local ok,err=xpcall(function()
        db=client.new()
        test('vector bulk insert and representation',function()
            local rows=db:from(name):insert{
                {run_id=run,label='east',embedding=vector.serialize{1,0,0}},
                {run_id=run,label='north',embedding=vector.serialize{0,1,0}},
                {run_id=run,label='diagonal',embedding=vector.serialize{1,1,0}},
            }:execute()
            eq(#rows,3)
        end)
        test('vector text round trip',function()
            local rows=db:from(name):select():filter{run_id=run,label='east'}:execute()
            eq(#rows,1); local v=vector.deserialize(rows[1].embedding)
            eq(#v,3); eq(v[1],1); eq(v[2],0); eq(v[3],0)
        end)
        test('L2 nearest RPC ranking and distances',function()
            local rows=search('l2');eq(#rows,3)
            eq(rows[1].label,'east');eq(rows[2].label,'diagonal');eq(rows[3].label,'north')
            near(rows[1].distance,math.sqrt(0.02));near(rows[2].distance,math.sqrt(0.82))
        end)
        test('cosine nearest RPC ranking and distances',function()
            local rows=search('cosine');eq(rows[1].label,'east')
            near(rows[1].distance,1-0.9/math.sqrt(0.82));eq(rows[2].label,'diagonal')
        end)
        test('inner product RPC ranking and negative distance',function()
            local rows=search('inner_product');eq(rows[1].label,'diagonal')
            near(rows[1].distance,-1);eq(rows[2].label,'east');near(rows[2].distance,-0.9)
        end)
        test('RPC result limit',function() eq(#search('l2',1),1) end)
        test('RPC run isolation',function() eq(#search('l2',3,run..'-other'),0) end)
        test('wrong vector dimension is rejected',function()
            local success,message=pcall(function()
                db:from(name):insert{run_id=run,label='invalid',embedding=vector.serialize{1,2}}:execute()
            end)
            assert(not success and tostring(message):find('400',1,true))
            eq(#db:from(name):select():filter{run_id=run}:execute(),3)
        end)
        test('invalid metric is rejected',function()
            local success,message=pcall(function() search('invalid') end)
            assert(not success and tostring(message):find('400',1,true))
        end)
        test('vector update affects nearest result',function()
            local rows=db:from(name):update{embedding=vector.serialize{0,0,1}}:filter{run_id=run,label='east'}:execute()
            eq(#rows,1);eq(search('l2')[1].label,'diagonal')
        end)
        test('delete only this run and confirm empty',function()
            eq(#db:from(name):delete():filter{run_id=run}:execute(),3)
            eq(#db:from(name):select():filter{run_id=run}:execute(),0)
            eq(#search('l2'),0)
        end)
    end,debug.traceback)
    if not ok then
        if db then
            local cleaned=pcall(function() db:from(name):delete():filter{run_id=run}:execute() end)
            if not cleaned then io.stderr:write('Cleanup failed for '..run..'\n') end
        end
        local message=tostring(err)
        if token~='' then message=message:gsub(token:gsub('([^%w])','%%%1'),'[redacted]') end
        io.stderr:write(message,'\n');io.stderr:flush();os.exit(1)
    end
    print('PASS: '..count..' shared pgvector PostgREST groups')
    os.exit(0)
end)
