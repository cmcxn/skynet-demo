local native = require 'skynet_postgres_native'
local sha2 = require 'sha2'
local function hex(s) return (s:gsub('.', function(c) return ('%02x'):format(c:byte()) end)) end
local function eq(a,b) assert(a==b, tostring(a)..' ~= '..tostring(b)) end
local random = assert(native.random_bytes, 'cross-platform secure random_bytes is missing')
eq(#assert(random(32)),32)
assert(random(32) ~= random(32))
for _,n in ipairs({0,-1,1.5,1048577}) do assert(not pcall(random,n)) end
print('PASS secure RNG and input limits')
eq(hex(native.sha256('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
eq(native.sha256('abc'),sha2.sha256('abc'))
eq(hex(native.hmac_sha256(string.rep('\11',20),'Hi There')), 'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7')
eq(hex(native.pbkdf2('password','salt',1,32)), '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b')
eq(native.md5('abc'),'900150983cd24fb0d6963f7d28e17f72')
assert(not pcall(native.pbkdf2,'p','s',0,32))
print('PASS SHA256/HMAC/PBKDF2/MD5 known vectors')
local vector=require 'pgvector'
eq(vector.serialize(vector.new({1,2,3})),'[1,2,3]')
eq(vector.deserialize('[1,2,3]')[2],2)
local u=require 'pgmoon.util'
eq(u.decode_base64(u.encode_base64('\0\255binary')),'\0\255binary')
print('PASS vector and binary base64 roundtrip')
local _, sparse = getmetatable(vector.sparsevec({[1000]=1,[2]=2,[600]=3},1000)).pgmoon_serialize(vector.sparsevec({[1000]=1,[2]=2,[600]=3},1000))
eq(sparse, '{2:2,600:3,1000:1}/1000')
print('PASS sparse vector indices are ordered')

if package.config:sub(1,1) == '\\' then
  local server = assert(native.system_dns_server())
  assert(server:match('^%d+%.%d+%.%d+%.%d+$'))
  print('PASS Windows native DNS discovery')
end
