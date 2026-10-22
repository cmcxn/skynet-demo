# Skynet PostgreSQL component

User-approved scope: vendor the database libraries from mao/game/lib into
components/skynet-postgres, retain provenance/licenses, repair TLS, timeouts and
Windows compatibility, and provide docs and tests. Source game code/data stays unchanged.

Keep pgmoon.new/query and pgvector APIs. Package the Lua libraries and an independent
OpenSSL 3 native TLS/crypto module in Docker, Windows portable and Linux native builds.
Default to verified TLS (chain plus DNS/IP SAN), never fall back to cleartext after
SSLRequest rejection. Explicit ssl=false is allowed for isolated local databases.
Use OpenSSL RAND_bytes, digests/HMAC/PBKDF2 for cross-platform SCRAM authentication;
retain sha2.lua for source compatibility. Support SCRAM-SHA-256 over verified TLS;
channel binding PLUS is outside scope and must never be silently claimed.

A connection is owned by one coroutine per operation. Serialize concurrent use by
rejecting overlapping connect/query operations, and document one connection per worker
or external skynet.queue for transactions. A finite timeout in milliseconds applies
to a complete connect/auth or query, including TLS and socket I/O. Timeouts and I/O
failures close the connection and never replay queries. DNS is asynchronous and
bounded for the caller; the shared resolver can finish its own in-flight lookup.

Verification uses Lua 5.5 tests, known crypto vectors, real ephemeral PostgreSQL with
pgvector and SCRAM, TLS trust/identity failures and refused SSL, timeouts/cleanup,
parameterized SQL and transactions, plus Windows cross-build and Wine runtime checks.
Existing HTTP/TLS/CA and LLM regressions remain enabled. No production DB is contacted.
