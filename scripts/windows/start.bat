@echo off
setlocal
cd /d "%~dp0"
set "SSL_CERT_FILE=%~dp0certs\ca-bundle.crt"
set "SSL_CERT_DIR=%~dp0certs"
skynet.exe examples\config
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
