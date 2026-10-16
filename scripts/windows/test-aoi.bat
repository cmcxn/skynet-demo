@echo off
setlocal
cd /d "%~dp0"
set "LUA_PATH=.\lualib\?.lua;;"
set "LUA_CPATH=.\luaclib\?.so;;"
lua.exe tests\aoi\unit.lua
if errorlevel 1 (
    echo FAIL: AOI offline tests
    exit /b 1
)
echo PASS: AOI offline tests
exit /b 0
