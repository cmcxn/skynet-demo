@echo off
setlocal
cd /d "%~dp0"
set "SSL_CERT_FILE=%~dp0certs\ca-bundle.crt"
set "SSL_CERT_DIR=%~dp0certs"
chcp 65001 >nul
lua.exe tests/llm-smoke.lua
if errorlevel 1 goto failed
tests\udp-errno.exe
if errorlevel 1 goto failed
lua.exe tests/llm-unit/protocol.lua
if errorlevel 1 goto failed
lua.exe tests/llm-unit/sse.lua
if errorlevel 1 goto failed
if /i "%~1"=="offline" goto offline
if exist llm-settings.bat call llm-settings.bat
if not defined LLM_API_KEY (
    echo Offline checks passed. Live checks skipped: copy llm-settings.example.bat to llm-settings.bat and fill in your API key.
    pause
    exit /b 2
)
if not defined SKYNET_LLM_DNS_SERVER (
    for /f "delims=" %%D in ('powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests\detect-dns.ps1') do set "SKYNET_LLM_DNS_SERVER=%%D"
)
if not defined SKYNET_LLM_DNS_SERVER (
    echo DNS discovery failed. Set SKYNET_LLM_DNS_SERVER in llm-settings.bat.
    goto failed
)
del /q llm-real-result.json llm-test-result.txt llm-test.log >nul 2>&1
echo Running live model tests. This sends billable API requests. start.bat is not required.
skynet.exe tests\config-llm > llm-test.log 2>&1
set "result=%errorlevel%"
type llm-test.log
if not exist llm-real-result.json (
    echo No fresh model report was produced.
    set "result=1"
)
echo Report: llm-real-result.json   Log: llm-test.log
if "%result%"=="0" (echo All model checks passed.) else (echo Some checks failed or the provider is incompatible. Inspect the report.)
pause
exit /b %result%
:offline
echo Offline LLM tests passed. No model requests were sent.
pause
exit /b 0
:failed
echo LLM test failed. Check the messages above.
pause
exit /b 1
