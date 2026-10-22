local skynet = require 'skynet'
local pgmoon = require 'pgmoon'
local vector = require 'pgvector'
local socket = require 'skynet.socket'
local function eq(a,b) assert(a==b, tostring(a)..' ~= '..tostring(b)) end
local count = 0
local function test(name, fn)
  fn(); count=count+1; print('PASS '..name)
end
local host = assert(os.getenv('PG_TEST_HOST'))
local fixtures = os.getenv('PG_TEST_FIXTURES') or '/fixtures'
local function config(overrides)
  local c = {host=host, port=5432, user='postgres', password='temporary-test-password',
    database='postgres', cafile=fixtures..'/ca.crt', ssl_server_name='db.test', timeout=5000}
  for k,v in pairs(overrides or {}) do c[k]=v end
  return c
end
local function connect(overrides)
  local p=pgmoon.new(config(overrides)); assert(p:connect()); return p
end
local function query(p, sql, ...) return assert(p:query(sql,...)) end
local function rejects(overrides, pattern)
  local p=pgmoon.new(config(overrides)); local ok,err=p:connect()
  assert(not ok, 'connection unexpectedly accepted'); assert(tostring(err):find(pattern), tostring(err))
  assert(not p.sock.fd and not p.sock.session and not p.sock.context, 'failed connect leaked resources')
  return err
end
skynet.start(function()
  local ok,err=xpcall(function()
    test('verified TLS and SCRAM authentication',function()
      local p=connect(); assert(p.sock.session)
      eq(query(p, 'SELECT 42 AS value')[1].value,42)
      assert(p:disconnect()); assert(p:disconnect()); assert(not p.sock.fd)
    end)
    test('notification wait owns connection and obeys deadline',function()
      local q=connect();query(q,'LISTEN component_events');q:settimeout(80)
      local done, result, failure
      skynet.fork(function() result,failure=q:wait_for_notification();done=true end)
      skynet.sleep(2)
      local rows,e=q:query('SELECT 1');assert(not rows and tostring(e):find('busy'),'notification wait did not reserve connection')
      skynet.sleep(20);assert(done and not result and tostring(failure):find('timeout'),'notification wait ignored timeout')
      assert(not q.sock.fd and not q.sock.session);q:disconnect()
    end)
    test('asynchronous DNS connection',function()
      local p=connect{host='db.test'};eq(query(p,'SELECT 4 AS n')[1].n,4);p:disconnect()
    end)
    test('TLS IP SAN verification',function()
      local p=connect{ssl_server_name='127.0.0.1'}; assert(p:disconnect())
    end)
    test('wrong CA rejected',function() rejects({cafile=fixtures..'/wrong-ca.crt'},'TLS') end)
    test('wrong DNS identity rejected',function() rejects({ssl_server_name='wrong.test'},'TLS') end)
    test('wrong IP identity rejected',function() rejects({ssl_server_name='127.0.0.2'},'TLS') end)
    test('missing CA rejected',function() rejects({cafile=fixtures..'/missing.crt'},'CA') end)
    test('default CA does not trust private server',function()
      local c=config();c.cafile=nil;local p=pgmoon.new(c);local yes=p:connect();assert(not yes);assert(not p.sock.fd)
    end)
    test('verification bypass is rejected',function()
      assert(not pcall(pgmoon.new,config{ssl_verify=false}))
    end)
    test('invalid timeout rejected',function()
      for _,v in ipairs({0,-1,1.5,math.huge,'100'}) do assert(not pcall(pgmoon.new,config{timeout=v})) end
    end)
    test('unsupported TLS options and invalid message limits rejected',function()
      for _,c in ipairs({{cert='client.pem'},{ssl='false'},{max_message_bytes=-1},{max_message_bytes=1.5}}) do
        assert(not pcall(pgmoon.new,config(c)))
      end
    end)
    test('wrong password fails and closes',function() rejects({password='wrong-password'},'authentication') end)
    test('explicit local plaintext connection',function()
      local p=connect{ssl=false}; assert(not p.sock.session);eq(query(p,'SELECT 7 AS n')[1].n,7);p:disconnect()
    end)
    local p=connect()
    test('parameterized SQL and NULL preserve values',function()
      local attack="x'; DROP TABLE absent; --"
      local r=query(p,'SELECT $1::text AS text, $2::int AS n, $3::boolean AS b, $4::text AS missing',attack,17,true,pgmoon.Postgres.NULL)[1]
      eq(r.text,attack);eq(r.n,17);eq(r.b,true);eq(r.missing,nil)
    end)
    test('convert_null preserves SQL NULL sentinel',function()
      local q=connect{convert_null=true};eq(query(q,'SELECT NULL::text AS missing')[1].missing,pgmoon.Postgres.NULL);q:disconnect()
    end)
    test('JSON arrays and bytea codecs',function()
      local r=query(p,"SELECT '{\"n\":3}'::jsonb AS j, ARRAY[1,2,3] AS a, decode('00ff','hex') AS bytes")[1]
      eq(r.j.n,3);eq(r.a[2],2);eq(r.bytes,'\0\255')
    end)
    test('SQL error drains response and keeps connection usable',function()
      local r,e=p:query('SELECT * FROM definitely_missing_table');assert(not r and e)
      eq(query(p,'SELECT 8 AS n')[1].n,8)
    end)
    test('transaction rollback and commit',function()
      query(p,'CREATE TEMP TABLE component_tx (n int)')
      query(p,'BEGIN');query(p,'INSERT INTO component_tx VALUES ($1)',1);query(p,'ROLLBACK')
      eq(query(p,'SELECT count(*)::int AS n FROM component_tx')[1].n,0)
      query(p,'BEGIN');query(p,'INSERT INTO component_tx VALUES ($1)',2);query(p,'COMMIT')
      eq(query(p,'SELECT n FROM component_tx')[1].n,2)
    end)
    test('pgvector dense/half/sparse parameters and nearest query',function()
      query(p,'CREATE EXTENSION IF NOT EXISTS vector');vector.setup_vector(p)
      query(p,'CREATE TEMP TABLE component_vectors (id int, embedding vector(3))')
      query(p,'INSERT INTO component_vectors VALUES ($1,$2),($3,$4)',1,vector.new{1,0,0},2,vector.new{0,1,0})
      local r=query(p,'SELECT id, embedding FROM component_vectors ORDER BY embedding <-> $1 LIMIT 1',vector.new{0.9,0.1,0})[1]
      eq(r.id,1);eq(r.embedding[1],1)
      local h=query(p,'SELECT $1::halfvec AS v',vector.halfvec{1,2,3})[1].v;eq(h[2],2);eq(query(p,'SELECT $1::halfvec AS v',h)[1].v[3],3)
      local s=query(p,'SELECT $1::sparsevec AS v',vector.sparsevec({[1]=1,[3]=2},3))[1].v;eq(s.dim,3);eq(s.elements[3],2);eq(query(p,'SELECT $1::sparsevec AS v',s)[1].v.dim,3)
    end)
    p:disconnect()
    test('deserializer cannot reenter the same connection',function()
      local q=connect()
      q:set_type_deserializer(23,'guarded_int',function(self,value)
        local nested,e=self:query('SELECT 999 AS n')
        assert(not nested and tostring(e):find('busy'),'deserializer reentered query protocol')
        return tonumber(value)
      end)
      eq(query(q,'SELECT 23::int AS n')[1].n,23)
      eq(query(q,'SELECT 24::int AS n')[1].n,24);q:disconnect()
    end)
    test('LISTEN notification payload',function()
      local listener=connect();query(listener,'LISTEN component_events')
      local writer=connect();query(writer,"SELECT pg_notify($1,$2)",'component_events','payload');writer:disconnect()
      local n=assert(listener:wait_for_notification());eq(n.channel,'component_events');eq(n.payload,'payload');listener:disconnect()
    end)
    test('query deadline closes resources and never reuses broken stream',function()
      local q=connect();q:settimeout(100);local began=skynet.now();local rows,e=q:query('SELECT pg_sleep(2)')
      assert(not rows and e:find('timeout'),tostring(e));assert(skynet.now()-began < 100)
      assert(not q.sock.fd and not q.sock.session and not q.sock.context)
      assert(not q:query('SELECT 1'));assert(q:connect());eq(query(q,'SELECT 1 AS n')[1].n,1);q:disconnect()
    end)
    test('concurrent queries reject the second owner',function()
      local q=connect();local done,success=false,false
      skynet.fork(function() success=q:query('SELECT pg_sleep(0.15)')~=nil;done=true end)
      skynet.sleep(2);local rows,e=q:query('SELECT 2');assert(not rows and e:find('busy'))
      while not done do skynet.sleep(1) end
      assert(success);eq(query(q,'SELECT 3 AS n')[1].n,3);q:disconnect()
    end)
    if os.getenv('PG_FAULT_HOST') then
      local fault=os.getenv('PG_FAULT_HOST')
      test('SSLRequest rejection never downgrades',function() rejects({host=fault,port=15432},'SSL') end)
      test('SSLRequest timeout closes socket',function() rejects({host=fault,port=15433,timeout=100},'timeout') end)
      test('TLS handshake timeout closes session and context',function() rejects({host=fault,port=15434,timeout=100},'timeout') end)
      test('invalid SCRAM server nonce rejected',function() rejects({host=fault,port=15437,ssl=false},'nonce') end)
      test('excessive SCRAM work factor rejected',function() rejects({host=fault,port=15438,ssl=false},'iteration%-count') end)
      test('PLUS-only SCRAM fails explicitly',function() rejects({host=fault,port=15439,ssl=false},'PLUS') end)
      test('expired server certificate rejected',function() rejects({host=fault,port=15436},'TLS') end)
      test('truncated protocol response fails and closes',function() rejects({host=fault,port=15435,ssl=false},'closed') end)
    end
  end,debug.traceback)
  if not ok then print('FAIL '..err) else print(('PASS all %d PostgreSQL integration groups'):format(count)) end
  -- os.exit is deliberate in this test-only process (also terminates Wine reliably).
  os.exit(ok and 0 or 1)
end)
