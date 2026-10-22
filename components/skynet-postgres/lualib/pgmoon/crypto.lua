-- OpenSSL 3 supplies the same secure primitives on Linux and Windows.
local native = require 'skynet_postgres_native'
return {
  random_bytes = native.random_bytes,
  md5 = native.md5,
  digest_sha256 = native.sha256,
  hmac_sha256 = native.hmac_sha256,
  kdf_derive_sha256 = function(password, salt, iterations)
    return native.pbkdf2(password, require('pgmoon.util').decode_base64(salt), iterations, 32)
  end,
  x509_digest = function() error('SCRAM-SHA-256-PLUS is not supported') end,
}
