@echo off
setlocal
cd /d "%~dp0"
lua.exe examples/client.lua
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
