@echo off
setlocal
cd /d "%~dp0"
set "SSL_CERT_FILE=%~dp0certs\ca-bundle.crt"
set "SSL_CERT_DIR=%~dp0certs"
if exist "%SystemRoot%\system32\chcp.com" chcp 65001 >nul
if exist postgrest-settings.bat call postgrest-settings.bat
if not defined DB_REST_URL (
    echo Set DB_REST_URL in postgrest-settings.bat or in the process environment.
    exit /b 2
)
if not defined DB_TIMEOUT_TICKS set "DB_TIMEOUT_TICKS=3000"
if not defined DB_TEST_RUN_ID set "DB_TEST_RUN_ID=windows-%RANDOM%-%RANDOM%-%RANDOM%"
skynet.exe tests\postgrest\config
exit /b %errorlevel%
