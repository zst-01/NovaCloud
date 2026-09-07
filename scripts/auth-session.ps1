#requires -Version 7.0
# 普通功能验收遵守服务器限流；限流专项脚本直接发送请求，不自动重试。
function Invoke-LabWebRequest {
    param([Parameter(Position=0)][string]$Uri, [string]$Method='Get', [hashtable]$Headers=@{},
          [string]$Body, [string]$ContentType, [int]$TimeoutSec=20, [switch]$SkipHttpErrorCheck)
    $parameters = @{Uri=$Uri;Method=$Method;Headers=$Headers;TimeoutSec=$TimeoutSec;SkipHttpErrorCheck=$true}
    if ($PSBoundParameters.ContainsKey('Body')) { $parameters.Body=$Body }
    if ($ContentType) { $parameters.ContentType=$ContentType }
    for ($attempt=0; $attempt -lt 3; $attempt++) {
        $response = Invoke-WebRequest @parameters
        if ($response.StatusCode -ne 429) { break }
        $seconds = 0
        if (-not [int]::TryParse(@($response.Headers['Retry-After'])[0], [ref]$seconds) -or $seconds -lt 1 -or $seconds -gt 60) {
            throw '429 响应缺少合理的 Retry-After；验收未自动绕过限制。'
        }
        if ($attempt -lt 2) {
            Write-Host "触发限流，等待 $seconds 秒后继续验收。"
            Start-Sleep -Seconds $seconds
        }
    }
    if (-not $SkipHttpErrorCheck -and $response.StatusCode -ge 400) { throw "HTTP 请求失败: $($response.StatusCode)" }
    return $response
}
function New-LabSession([string]$BaseUrl = 'http://127.0.0.1:18080', [string]$Username = 'demo') {
    $envPath = Join-Path (Split-Path $PSScriptRoot -Parent) '.env'
    $line = Get-Content -LiteralPath $envPath | Where-Object { $_ -match '^DEMO_PASSWORD=' } | Select-Object -First 1
    if (-not $line) { throw '缺少 DEMO_PASSWORD，请先运行启动脚本。' }
    $body = @{username=$Username;password=$line.Substring('DEMO_PASSWORD='.Length)} | ConvertTo-Json -Compress
    $response = Invoke-LabWebRequest "$BaseUrl/api/auth/login" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 20
    $session = $response.Content | ConvertFrom-Json
    if ($session.token -cnotmatch '^[0-9a-f]{64}$' -or $session.expiresIn -ne 1800) { throw '登录响应不符合约定' }
    return @{Authorization="Bearer $($session.token)"}
}
function Remove-LabSession($Headers, [string]$BaseUrl = 'http://127.0.0.1:18080') {
    if ($Headers) {
        $response = Invoke-WebRequest "$BaseUrl/api/auth/logout" -Method Post -Headers $Headers -SkipHttpErrorCheck -TimeoutSec 20
        if ($response.StatusCode -notin @(200,401)) { throw "清理测试会话失败: $($response.StatusCode)" }
    }
}
