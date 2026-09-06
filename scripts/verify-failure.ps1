$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    . "$PSScriptRoot/auth-session.ps1"
    $authHeaders = New-LabSession
    & "$PSScriptRoot/verify.ps1"
    try {
        docker compose stop platform-gateway
        if ($LASTEXITCODE -ne 0) { throw '停止中台网关失败' }
        $response = Invoke-WebRequest 'http://127.0.0.1:18080/api/tickets/1' -Headers $authHeaders -SkipHttpErrorCheck -TimeoutSec 20
        $body = $response.Content | ConvertFrom-Json
        $expected = ($response.StatusCode -eq 502 -and $body.error -eq 'platform_unavailable') -or
                    ($response.StatusCode -eq 504 -and $body.error -eq 'platform_timeout')
        if (-not $expected) { throw "故障响应不符合约定: $($response.StatusCode) $($response.Content)" }
        Write-Host "PASS: 中台网关停止后返回 $($response.StatusCode) / $($body.error)"
    } finally {
        docker compose up -d --wait --wait-timeout 180 platform-gateway
        if ($LASTEXITCODE -ne 0) { throw '中台网关恢复失败' }
    }
    & "$PSScriptRoot/verify.ps1"
} finally { try { Remove-LabSession -Headers $authHeaders } finally { Pop-Location } }
