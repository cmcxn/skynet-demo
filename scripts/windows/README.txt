Skynet master 64391f7 + skynet-llm - portable Windows x64 test package

Extract the ENTIRE folder before running. Keep all DLLs and subfolders.
No Docker, MinGW, Lua or OpenSSL installation is needed on the destination PC.
Double-click start.bat to start the demo (TCP 8888).
Double-click client.bat in another window for the interactive demo client.
With start.bat running, double-click test.bat to check modules, HTTPS and TCP set/get.
The HTTPS checks require Internet access and a 30-second timeout per request.
They GET https://www.baidu.com/ and require HTTP 200 with a nonempty body.
They GET https://httpbin.org/ip, decode JSON and print the nonempty origin field.
Each HTTPS check prints PASS or FAIL; failed requests make test.bat fail.
To run only HTTPS checks, double-click test-https.bat; start.bat is not required.
Stop the server with Ctrl+C in the server window.
Use a separate copy for each instance. Ports 8888, 8000, 2013 and 2526 must be free.
The example database is in memory; restarting loses the data.

Includes Lua 5.5.1, lua-cjson and statically linked OpenSSL 3.5.9 for HTTPS.
lua54.dll is the upstream build's legacy filename; its contents are Lua 5.5.1.
All native modules are rebuilt together. Do not mix DLLs with an older package.
Native .so files are Windows DLLs, retaining Skynet's standard module filenames.
The patched ltls client verifies server certificates and DNS/IP identities.
Both ltls and skynet_llm_tls use the updated bundled CA file.
Launch BAT files set SSL_CERT_FILE/SSL_CERT_DIR for this process.
certs/source-package.txt and certs/SHA256SUMS identify the shipped trust bundle.
Replace the entire old package after a CA security update.
This package keeps the upstream example's network binding configuration.

Windows compatibility code and mingw.mk come directly from cloudwu/skynet
master commit 64391f732e76507ea6615f312cb71be1fd7bfbdd.
The old MinGW backport patch is removed. Upstream already fixes sleep() units.
The Windows demo omits the POSIX stdin console; use client.bat instead.
Licenses, the compatibility patch and PATCH-SOURCES.md are in licenses/.

LLM TESTS (Windows 10/11 x64)

1. Copy llm-settings.example.bat to llm-settings.bat.
2. Edit llm-settings.bat and fill in your own LLM_API_KEY, endpoints and models.
   The archive contains NO real API key. Keep your edited settings file private.
3. Double-click test-llm.bat. start.bat is not required.

The test first loads the Windows TLS module and bundled CA certificates, checks
UDP would-block error translation, then runs 31 protocol and 6 SSE checks.
Run "test-llm.bat offline" in cmd.exe to stop
there without sending model requests. Normal live mode sends billable requests
for Chat, Chat streaming, function tools, tool continuation, Embeddings,
Responses and Responses tools/streaming.

DNS is detected from an IPv4 default-route adapter using Windows PowerShell.
If discovery fails or you use a VPN/private DNS, set SKYNET_LLM_DNS_SERVER in
llm-settings.bat to the IPv4 DNS address shown by "ipconfig /all" (optional :port).
The LLM transport uses cancellable IPv4 UDP DNS; it does not use Windows DoH,
IPv6-only DNS, a system HTTP proxy, or the Windows certificate store.
test-llm.bat sets SSL_CERT_FILE to certs/ca-bundle.crt for this process only.
Refresh that PEM bundle if your trust roots change; add your private CA there
when needed. Do not disable certificate or hostname verification.

Live results: llm-real-result.json, llm-test.log and llm-test-result.txt.
Return code 0 means all requested checks passed; 1 means a failure or provider
incompatibility; 2 means the key is missing and live checks were skipped.
The default gateway passed 8 live checks in Linux Docker. Its Responses stream
omits required output/content indexes, and reasoning lacks replayable encrypted
content: those two checks are INCOMPATIBLE and intentionally return a nonzero
exit code. They must not be counted as a successful Windows runtime test.

The archive was cross-compiled and inspected as Windows x64 PE binaries.
Windows runtime execution is to be verified on your destination PC.
It includes the unofficial one-shot receive-credit patch (128 KiB per
grant) and a Windows UDP error-code fix. These patches apply only to build
copies; originals and licenses
are in licenses/. Future Skynet upgrades require reviewing both patches.

Wine 10.0 x64 (Docker) verification: offline BAT and native TLS load, original
demo/JSON/HTTPS/TCP checks, 36 transport checks, client and lifecycle checks.
Near-32-MiB streaming and cancellation stayed within the 128-KiB receive bound.
Live Wine model checks returned 8 PASS and the same 2 provider incompatibilities
listed above. Wine used an explicit DNS override; the Windows PowerShell DNS
discovery script still needs validation on a Windows PC.

本次 master 迁移验收：64391f732e76507ea6615f312cb71be1fd7bfbdd，Lua 5.5.1。
Linux 全套 mock 测试通过；Wine 离线 31 协议 + 6 SSE、36 传输、客户端及生命周期通过。
真实模型 8 项通过；Responses SSE 缺少索引、reasoning 无法重放两项服务兼容性限制仍存在。

Pluto AOI: run test-aoi.bat for offline AOI tests. Business code should require
"skynet_aoi". See licenses/pluto-aoi/README.md for API and upstream limitations.

POSTGREST (self-hosted or CloudBase PG REST)

Open CMD in the extracted package directory. Copy postgrest-local.example.bat
or postgrest-cloudbase.example.bat to postgrest-settings.bat and edit its values.
Run test-postgrest.bat. You do not need start.bat. No Docker is needed on Windows
when connecting to an existing PostgREST server or CloudBase environment.

Both modes use DB_REST_URL, DB_REST_TOKEN and DB_TIMEOUT_TICKS (3000 = 30s).
Use a Windows-reachable HTTP address for self-hosted PostgREST; Docker service
names such as "postgrest" only resolve inside that Docker network.
The CloudBase URL is https://<envId>.api.tcloudbasegateway.com/v1/rdb/rest.
Keep the service-role API Key private. Do not ship your edited settings file.
The ZIP contains only empty/example settings; all credentials are runtime-only.

Prepare skynet_postgrest_test_20261026(id text PRIMARY KEY, task text NOT NULL,
done boolean NOT NULL DEFAULT false) on the target before testing. Grant the
caller CRUD access. For CloudBase use the separately documented service_role
setup; enabling RLS alone does not grant ordinary users access.
The shared suite runs 8 checks and deletes only its own test ID, keeping the table.
It uses bundled PEM CA certificates, verifies HTTPS identity and connects directly.
The script exits 0 only if the service process and all checks succeed.
Business code: local db = require('skynet_postgrest_client').new()
