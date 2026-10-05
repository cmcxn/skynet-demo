@echo off
setlocal
cd /d "%~dp0"
skynet.exe examples\config
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
