param([Parameter(Mandatory=$true)][string]$Archive, [Parameter(Mandatory=$true)][string]$ExpectedSha)
$ErrorActionPreference = 'Stop'
$Archive = (Resolve-Path $Archive).Path
$expectedHash = ((Get-Content "$Archive.sha256").Split(' ')[0]).ToLowerInvariant()
if ((Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) { throw 'ZIP checksum mismatch' }
$stage = Join-Path $env:RUNNER_TEMP ('Skynet native test ' + [guid]::NewGuid().ToString('N'))
Expand-Archive -LiteralPath $Archive -DestinationPath $stage
$root = Join-Path $stage 'skynet-windows-x64'
$info = Get-Content (Join-Path $root 'BUILD-INFO.json') | ConvertFrom-Json
if ($info.source_commit -ne $ExpectedSha) { throw 'Package source commit mismatch' }
python "$PSScriptRoot/windows-package.py" $root
if ($LASTEXITCODE -ne 0) { throw 'Package audit failed' }
Copy-Item "$PSScriptRoot/windows-service.lua" "$root/tests/"
Copy-Item "$PSScriptRoot/windows-config" "$root/tests/"
$env:SSL_CERT_FILE = "$root/certs/ca-bundle.crt"
$env:SSL_CERT_DIR = "$root/certs"
$env:LUA_PATH = '.\lualib\?.lua;.\lualib\?\init.lua;;'
$env:LUA_CPATH = '.\luaclib\?.so;;'
function Invoke-Package([string]$Exe, [string]$Arguments, [int]$Seconds = 60) {
    $si = [Diagnostics.ProcessStartInfo]::new()
    $si.FileName = Join-Path $root $Exe
    $si.Arguments = $Arguments
    $si.WorkingDirectory = $root
    $si.UseShellExecute = $false
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($si)
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($Seconds * 1000)) { $p.Kill($true); throw "Timeout: $Exe $Arguments" }
    Write-Host $stdout.Result
    Write-Host $stderr.Result
    if ($p.ExitCode -ne 0) { throw "Exit $($p.ExitCode): $Exe $Arguments" }
    $p.Dispose()
}
Invoke-Package 'lua.exe' 'tests/smoke.lua'
Invoke-Package 'lua.exe' 'tests/llm-smoke.lua'
Invoke-Package 'tests/udp-errno.exe' ''
Invoke-Package 'lua.exe' 'tests/llm-unit/protocol.lua'
Invoke-Package 'lua.exe' 'tests/llm-unit/sse.lua'
Invoke-Package 'lua.exe' 'tests/aoi/unit.lua'
Invoke-Package 'skynet.exe' 'tests\windows-config'
if ((Get-Content "$root/ci-service-result.txt") -ne 'PASS') { throw 'Service module check failed' }
# Test the shipped demo twice. Each stop must release the TCP listener before restart.
foreach ($cycle in 1..2) {
    $server = Start-Process -FilePath "$root/skynet.exe" -ArgumentList 'examples\config' -WorkingDirectory $root -PassThru -RedirectStandardOutput "$stage/server-$cycle.out" -RedirectStandardError "$stage/server-$cycle.err"
    try {
        $ready = $false
        foreach ($attempt in 1..30) {
            if ($server.HasExited) { throw 'Demo exited before readiness' }
            $client = [Net.Sockets.TcpClient]::new()
            try { $client.Connect('127.0.0.1',8888); $ready = $true; break } catch { Start-Sleep -Milliseconds 500 } finally { $client.Dispose() }
        }
        if (-not $ready) { throw 'Demo readiness timeout' }
        Invoke-Package 'lua.exe' 'tests/demo-client.lua' 30
    } finally {
        if (-not $server.HasExited) { $server.Kill($true); $server.WaitForExit() }
        Get-Content "$stage/server-$cycle.err" | Write-Host
        $server.Dispose()
    }
    $probe = [Net.Sockets.TcpClient]::new()
    try { $probe.Connect('127.0.0.1',8888); throw 'TCP listener remains after stop' }
    catch [Net.Sockets.SocketException] { Write-Host "PASS: demo start/TCP/forced stop cycle $cycle" }
    finally { $probe.Dispose() }
}
if ((Get-FileHash $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash) { throw 'Test changed release ZIP' }
Write-Host 'PASS: native Windows x64 package validation; original ZIP unchanged'
