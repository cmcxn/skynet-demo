$ErrorActionPreference = 'Stop'
try {
    $address = Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
        Sort-Object RouteMetric |
        ForEach-Object { Get-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 } |
        ForEach-Object { $_.ServerAddresses } |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
        Select-Object -First 1
    if (-not $address) { throw 'No IPv4 DNS server on a default-route interface.' }
    Write-Output $address
} catch {
    [Console]::Error.WriteLine('Set SKYNET_LLM_DNS_SERVER manually in llm-settings.bat (see ipconfig /all).')
    exit 1
}
