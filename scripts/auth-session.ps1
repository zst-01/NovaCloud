#requires -Version 7.0
function New-LabSession([string]$BaseUrl = 'http://127.0.0.1:18080', [string]$Username = 'demo') {
    $envPath = Join-Path (Split-Path $PSScriptRoot -Parent) '.env'
    $line = Get-Content -LiteralPath $envPath | Where-Object { $_ -match '^DEMO_PASSWORD=' } | Select-Object -First 1
    if (-not $line) { throw '缺少 DEMO_PASSWORD，请先运行启动脚本。' }
    $body = @{username=$Username;password=$line.Substring('DEMO_PASSWORD='.Length)} | ConvertTo-Json -Compress
    $session = Invoke-RestMethod "$BaseUrl/api/auth/login" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 20
    if ($session.token -cnotmatch '^[0-9a-f]{64}$' -or $session.expiresIn -ne 1800) { throw '登录响应不符合约定' }
    return @{Authorization="Bearer $($session.token)"}
}
function Remove-LabSession($Headers, [string]$BaseUrl = 'http://127.0.0.1:18080') {
    if ($Headers) {
        $response = Invoke-WebRequest "$BaseUrl/api/auth/logout" -Method Post -Headers $Headers -SkipHttpErrorCheck -TimeoutSec 20
        if ($response.StatusCode -notin @(200,401)) { throw "清理测试会话失败: $($response.StatusCode)" }
    }
}
