Skynet v1.8.0 - portable Windows x64 demo

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

Includes Lua 5.4, lua-cjson and statically linked OpenSSL 3.5.9 for HTTPS.
Native .so files are Windows DLLs, retaining Skynet's standard module filenames.
The upstream v1.8.0 TLS client does not verify server certificates/hostnames.
This package keeps the upstream example's network binding configuration.

Windows compatibility code is backported from cloudwu/skynet commits:
234e134967da2f1295fc671910e47439cd47f3b1 (MinGW support)
4b7addb (sys/select.h compatibility header).
The backport omits newer mem_info.c and unrelated Makefile/platform changes.
It also fixes the compatibility sleep() wrapper to accept seconds.
The Windows demo omits the POSIX stdin console; use client.bat instead.
Licenses, the compatibility patch and PATCH-SOURCES.md are in licenses/.
