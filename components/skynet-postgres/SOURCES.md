# Source provenance

Imported on 2026-10-22 from `/Users/mac/Documents/mao/game/lib` at parent commit
`f2c01c8ce630f994c3922123a9a2d4e0201f1495`. Exact imported file hashes are recorded
in SOURCE-SHA256.json (before our changes). This is a direct source copy, not a submodule.
No game services, private configurations, credentials or data are imported.

- pgmoon reports VERSION=1.16.0. Upstream https://github.com/leafo/pgmoon, MIT;
  license captured from upstream README at `3bd08cbab408bc9540217054e59f35a4788317b5`.
  This license reference does not claim the modified local copy equals that commit.
- pgvector.lua: upstream https://github.com/pgvector/pgvector-lua, MIT; license
  captured at `0915e0dd8be4bf10b2add249fd4b50cfe652d4ef`. Original local revision
  was not recorded by the source repository; the imported file hash is authoritative.
- socket.lua, crypto.lua, util.lua, sha2.lua contain local Skynet adaptations.
  No separate local license was supplied. Preserve their provenance; do not
  misrepresent them as byte-identical upstream code.
- Native TLS is an independent snapshot of this repository's
  components/skynet-llm/lualib-src/skynet_llm_tls.c at master e81de10;
  original Skynet MIT notice retained. Added OpenSSL RNG and crypto functions.

Local changes: verified TLS by default with no opportunistic downgrade; real
operation deadlines; resource cleanup and concurrent-use rejection; Windows
OpenSSL RNG and native system DNS discovery; strict SCRAM nonce/iteration bounds; transport frame limits.
