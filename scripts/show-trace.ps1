#requires -Version 7.0
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$TraceId,
    [string]$Since = '30m',
    [ValidateSet('Compose','Kubernetes')][string]$Runtime = 'Compose'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/container-runtime.ps1"
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    $lines = @(Get-LabLogs -Since $Since)
    if ($LASTEXITCODE -ne 0) { throw '读取容器日志失败，请确认 Docker 正常运行' }
    $found = @($lines | Where-Object { "$_".Contains($TraceId) })
    if ($found.Count -eq 0) { throw '此时间范围未找到编号；可调整 -Since，容器重建或日志轮转也可能清除旧记录' }
    $found | ForEach-Object { Write-Output "$_" }
} finally { Pop-Location }
