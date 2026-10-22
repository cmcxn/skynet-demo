@echo off
setlocal
cd /d "%~dp0"
set "SSL_CERT_FILE=%~dp0certs\ca-bundle.crt"
set "SSL_CERT_DIR=%~dp0certs"
echo Testing Baidu HTTPS and httpbin HTTPS JSON. Internet access is required.
skynet.exe tests\config-https
set "result=%errorlevel%"
if "%result%"=="0" (echo HTTPS tests passed.) else (echo HTTPS tests failed.)
pause
exit /b %result%
