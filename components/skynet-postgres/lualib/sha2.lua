-- Pure Lua 5.3+/5.4 SHA-256 implementation (uses native 64-bit integers and
-- bitwise operators, no external C dependency). Also provides HMAC-SHA256
-- and PBKDF2-HMAC-SHA256, which is all pgmoon needs to perform PostgreSQL's
-- SCRAM-SHA-256 authentication handshake.
--
-- Written for the Skynet Lua runtime (Lua 5.3+ semantics: `&`, `|`, `~`,
-- `<<`, `>>` bitwise operators and 64-bit integers).

local sha2 = {}

local MASK32 = 0xFFFFFFFF

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function rotr(x, n)
  x = x & MASK32
  return ((x >> n) | (x << (32 - n))) & MASK32
end

-- SHA-256 over a binary string, returns a 32-byte binary digest.
function sha2.sha256(msg)
  local h0, h1, h2, h3, h4, h5, h6, h7 =
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

  local len = #msg
  local bitlen = len * 8
  msg = msg .. "\128"
  while (#msg % 64) ~= 56 do
    msg = msg .. "\0"
  end
  -- append 64-bit big-endian bit length
  for i = 7, 0, -1 do
    msg = msg .. string.char((bitlen >> (i * 8)) & 0xFF)
  end

  local w = {}
  for chunk_start = 1, #msg, 64 do
    for i = 0, 15 do
      local o = chunk_start + i * 4
      local b1, b2, b3, b4 = msg:byte(o, o + 3)
      w[i + 1] = ((b1 << 24) | (b2 << 16) | (b3 << 8) | b4) & MASK32
    end
    for i = 17, 64 do
      local w15, w2 = w[i - 15], w[i - 2]
      local s0 = rotr(w15, 7) ~ rotr(w15, 18) ~ (w15 >> 3)
      local s1 = rotr(w2, 17) ~ rotr(w2, 19) ~ (w2 >> 10)
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & MASK32
    end

    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 1, 64 do
      local s1 = rotr(e, 6) ~ rotr(e, 11) ~ rotr(e, 25)
      local ch = (e & f) ~ ((~e & MASK32) & g)
      local temp1 = (h + s1 + ch + K[i] + w[i]) & MASK32
      local s0 = rotr(a, 2) ~ rotr(a, 13) ~ rotr(a, 22)
      local maj = (a & b) ~ (a & c) ~ (b & c)
      local temp2 = (s0 + maj) & MASK32

      h = g
      g = f
      f = e
      e = (d + temp1) & MASK32
      d = c
      c = b
      b = a
      a = (temp1 + temp2) & MASK32
    end

    h0 = (h0 + a) & MASK32
    h1 = (h1 + b) & MASK32
    h2 = (h2 + c) & MASK32
    h3 = (h3 + d) & MASK32
    h4 = (h4 + e) & MASK32
    h5 = (h5 + f) & MASK32
    h6 = (h6 + g) & MASK32
    h7 = (h7 + h) & MASK32
  end

  local function be32(x)
    return string.char((x >> 24) & 0xFF, (x >> 16) & 0xFF, (x >> 8) & 0xFF, x & 0xFF)
  end

  return be32(h0) .. be32(h1) .. be32(h2) .. be32(h3)
    .. be32(h4) .. be32(h5) .. be32(h6) .. be32(h7)
end

-- HMAC-SHA256(key, message), both binary strings in, 32-byte binary digest out.
function sha2.hmac_sha256(key, message)
  local blocksize = 64
  if #key > blocksize then
    key = sha2.sha256(key)
  end
  key = key .. string.rep("\0", blocksize - #key)

  local o_key_pad = {}
  local i_key_pad = {}
  for i = 1, blocksize do
    local kb = key:byte(i)
    o_key_pad[i] = string.char(kb ~ 0x5c)
    i_key_pad[i] = string.char(kb ~ 0x36)
  end
  o_key_pad = table.concat(o_key_pad)
  i_key_pad = table.concat(i_key_pad)

  return sha2.sha256(o_key_pad .. sha2.sha256(i_key_pad .. message))
end

-- PBKDF2-HMAC-SHA256(password, salt, iterations, dklen), salt/password/output
-- are all raw binary strings.
function sha2.pbkdf2_hmac_sha256(password, salt, iterations, dklen)
  dklen = dklen or 32
  local hlen = 32
  local l = math.ceil(dklen / hlen)
  local dk = {}

  for i = 1, l do
    local int_be = string.char(
      (i >> 24) & 0xFF, (i >> 16) & 0xFF, (i >> 8) & 0xFF, i & 0xFF
    )
    local u = sha2.hmac_sha256(password, salt .. int_be)
    local t = u
    for _ = 2, iterations do
      u = sha2.hmac_sha256(password, u)
      local xored = {}
      for j = 1, #t do
        xored[j] = string.char(t:byte(j) ~ u:byte(j))
      end
      t = table.concat(xored)
    end
    dk[i] = t
  end

  return table.concat(dk):sub(1, dklen)
end

return sha2
