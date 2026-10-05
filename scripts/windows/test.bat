@echo off
setlocal
cd /d "%~dp0"
lua.exe tests/smoke.lua
if errorlevel 1 goto failed
echo Testing Baidu HTTPS and httpbin HTTPS JSON. Internet access is required.
skynet.exe tests\config-https
if errorlevel 1 goto failed
echo Testing TCP demo on 127.0.0.1:8888. Start start.bat first.
lua.exe tests/demo-client.lua
if errorlevel 1 goto failed
echo All tests passed.
pause
exit /b 0
:failed
echo Test failed. Check the messages above, Internet access and start.bat.
pause
exit /b 1
