#requires -Version 7.0
param([ValidateSet('Start','Stop')][string]$Action = 'Start', [ValidateSet('nginx','nacos','All')][string]$Service = 'All')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/container-runtime.ps1"
$localDir = Join-Path (Split-Path $PSScriptRoot -Parent) '.k8s-local'
New-Item -ItemType Directory -Force -Path $localDir | Out-Null
$services = if ($Service -eq 'All') { @('nginx','nacos') } else { @($Service) }
foreach ($name in $services) {
    $stateFile = Join-Path $localDir "forward-$name.json"
    if (Test-Path -LiteralPath $stateFile) {
        $state = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
        $owned = Get-Process -Id $state.ProcessId -ErrorAction SilentlyContinue
        if ($owned -and $owned.ProcessName -eq 'kubectl' -and $owned.StartTime.ToUniversalTime().Ticks -eq $state.StartTicks) {
            Stop-Process -Id $owned.Id
            $owned.WaitForExit(5000) | Out-Null
        }
        Remove-Item -LiteralPath $stateFile
    }
    if ($Action -eq 'Stop') { continue }
    $localPort = if ($name -eq 'nginx') { 28080 } else { 28848 }
    $remotePort = if ($name -eq 'nginx') { 80 } else { 8848 }
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$localPort)
    try { $probe.Start() } catch { throw "端口 $localPort 已被其他进程占用；未终止该进程。" } finally { $probe.Stop() }
    $process = Start-Process -FilePath (Get-Command kubectl).Source -WindowStyle Hidden -PassThru `
        -ArgumentList @('--context','docker-desktop','-n',(Get-LabNamespace $name),'port-forward',"service/$name","${localPort}:$remotePort",'--address=127.0.0.1') `
        -RedirectStandardOutput (Join-Path $localDir "forward-$name.out.log") `
        -RedirectStandardError (Join-Path $localDir "forward-$name.err.log")
    @{ProcessId=$process.Id;StartTicks=$process.StartTime.ToUniversalTime().Ticks} | ConvertTo-Json | Set-Content -LiteralPath $stateFile
    $ready = $false
    for ($attempt=0; $attempt -lt 40; $attempt++) {
        if ($process.HasExited) { throw "$name 端口转发退出；查看 .k8s-local/forward-$name.err.log" }
        $client = [System.Net.Sockets.TcpClient]::new()
        try { $client.Connect('127.0.0.1',$localPort); $ready=$true; break } catch { Start-Sleep -Milliseconds 250 } finally { $client.Dispose() }
    }
    if (-not $ready) { throw "$name 端口转发未就绪" }
    Write-Host "Kubernetes $name 本机入口：http://127.0.0.1:$localPort"
}
