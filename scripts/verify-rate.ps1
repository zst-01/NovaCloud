#requires -Version 7.0
param([string]$BaseUrl='http://127.0.0.1:18080', [int]$LoginLimit=10, [int]$TicketLimit=20, [switch]$IncludeFailure)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/auth-session.ps1"
Push-Location (Split-Path $PSScriptRoot -Parent)
$first = $null
$second = $null
function Wait-Quota($Response) {
    $seconds = 0
    if (-not [int]::TryParse(@($Response.Headers['Retry-After'])[0], [ref]$seconds) -or $seconds -lt 1 -or $seconds -gt 60) {
        throw '限流响应必须提供 1..60 秒的 Retry-After'
    }
    Write-Host "等待窗口恢复：$seconds 秒。"
    Start-Sleep -Seconds $seconds
}
function Assert-Limited($Response) {
    if ($Response.StatusCode -ne 429 -or ($Response.Content | ConvertFrom-Json).error -ne 'rate_limited') { throw '未返回约定的 429' }
    if (@($Response.Headers['X-Trace-Id'])[0] -cnotmatch '^[0-9a-f]{32}$') { throw '429 缺少 TraceId' }
}
try {
    $first = New-LabSession -BaseUrl $BaseUrl
    $second = New-LabSession -BaseUrl $BaseUrl
    # 不删除已有计数。先耗尽当前窗口，然后按 Retry-After 等待完整的新窗口。
    for ($i=0; $i -le $LoginLimit; $i++) {
        $r = Invoke-WebRequest "$BaseUrl/api/auth/login" -Method Post -ContentType 'application/json' -Body '{"username":"demo","password":"rate-test-wrong"}' -SkipHttpErrorCheck
        if ($r.StatusCode -eq 429) { break }
        if ($r.StatusCode -ne 401) { throw "登录测试出现非预期状态 $($r.StatusCode)" }
    }
    Assert-Limited $r
    $r = Invoke-WebRequest "$BaseUrl/api/auth/login" -Method Post -ContentType 'application/json' -Body '{"username":"demo","password":"rate-test-wrong"}' -Headers @{'X-Lab-Client-IP'='203.0.113.17';'X-Forwarded-For'='203.0.113.19'} -SkipHttpErrorCheck
    Assert-Limited $r
    Write-Host 'PASS: 登录超额返回 429，伪造 IP 头不能绕过 Nginx'
    Wait-Quota $r
    $loginResults = 1..($LoginLimit+1) | ForEach-Object -Parallel {
        $r = Invoke-WebRequest "$using:BaseUrl/api/auth/login" -Method Post -ContentType 'application/json' -Body '{"username":"demo","password":"rate-test-wrong"}' -Headers @{'X-Lab-Client-IP'="198.51.100.$_"} -SkipHttpErrorCheck -TimeoutSec 20
        @{Status=[int]$r.StatusCode;Trace=@($r.Headers['X-Trace-Id'])[0]}
    } -ThrottleLimit 11
    if (@($loginResults | Where-Object Status -eq 401).Count -ne $LoginLimit -or @($loginResults | Where-Object Status -eq 429).Count -ne 1) {
        throw '并发登录额度不符合配置，或实验期间有其他同来源请求'
    }
    Write-Host "PASS: 新窗口并发登录恰好放行 $LoginLimit 次，其余返回 429；成功和失败登录均计数"
    for ($i=0; $i -le $TicketLimit; $i++) {
        $r = Invoke-WebRequest "$BaseUrl/api/tickets/1" -Headers $first -SkipHttpErrorCheck -TimeoutSec 20
        if ($r.StatusCode -eq 429) { break }
        if ($r.StatusCode -ne 200) { throw '工单限流预备请求失败' }
    }
    Assert-Limited $r
    Wait-Quota $r
    $pairs = @($first,$second)
    $ticketResults = 1..($TicketLimit+1) | ForEach-Object -Parallel {
        $headers = ($using:pairs)[$_ % 2]
        $r = Invoke-WebRequest "$using:BaseUrl/api/tickets/1" -Headers $headers -SkipHttpErrorCheck -TimeoutSec 20
        @{Status=[int]$r.StatusCode;Trace=@($r.Headers['X-Trace-Id'])[0]}
    } -ThrottleLimit 21
    if (@($ticketResults | Where-Object Status -eq 200).Count -ne $TicketLimit -or @($ticketResults | Where-Object Status -eq 429).Count -ne 1) {
        throw '并发工单额度不符合配置，或实验期间有其他 demo 请求'
    }
    $r = Invoke-WebRequest "$BaseUrl/api/%74ickets/1" -Headers $second -SkipHttpErrorCheck
    Assert-Limited $r
    $r = Invoke-WebRequest "$BaseUrl/api/tickets;x=y/1" -Headers $second -SkipHttpErrorCheck
    Assert-Limited $r
    Write-Host "PASS: 同一用户两个 token 共用 $TicketLimit 次额度，特殊路径也被限流"
    $blocked = $r
    $r = Invoke-WebRequest "$BaseUrl/api/auth/me" -Headers $second
    if ($r.StatusCode -ne 200) { throw '个人信息接口不应被工单额度限制' }
    Remove-LabSession -Headers $first -BaseUrl $BaseUrl
    $first = $null
    Write-Host 'PASS: 工单超额后仍可查询自身信息和退出'
    Wait-Quota $blocked
    $r = Invoke-WebRequest "$BaseUrl/api/tickets/1" -Headers $second
    if ($r.StatusCode -ne 200) { throw '工单窗口恢复失败' }
    Write-Host 'PASS: 工单窗口到期后恢复查询'
    if ($IncludeFailure) {
        try {
            docker compose stop redis
            if ($LASTEXITCODE -ne 0) { throw '停止 Redis 失败' }
            $r = Invoke-WebRequest "$BaseUrl/api/auth/login" -Method Post -ContentType 'application/json' -Body '{}' -SkipHttpErrorCheck -TimeoutSec 20
            if ($r.StatusCode -ne 503 -or ($r.Content | ConvertFrom-Json).error -ne 'rate_limit_unavailable') { throw 'Redis 故障时登录限流未拒绝访问' }
            Write-Host 'PASS: Redis 故障时登录限流返回 503'
        } finally {
            docker compose up -d --wait --wait-timeout 180
            if ($LASTEXITCODE -ne 0) { throw 'Redis 故障实验后服务未恢复健康' }
        }
    }
    $traces = @($loginResults + $ticketResults | Where-Object Status -eq 429 | ForEach-Object { $_.Trace })
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $lines = @(docker compose logs --since 5m --no-color nginx app-gateway app-service platform-gateway platform-service 2>&1)
        if ($LASTEXITCODE -ne 0) { throw '读取限流日志失败' }
        $complete = $true
        foreach ($trace in $traces) {
            if ($trace -cnotmatch '^[0-9a-f]{32}$') { throw '并发 429 响应缺少合法 TraceId' }
            $completionLines = @($lines | Where-Object { "$_".Contains($trace) -and "$_" -match 'request_complete' })
            if ($completionLines.Count -ne 2 -or @($completionLines | Where-Object { "$_" -match '^(nginx|app-gateway)-\d+\s+\|' -and "$_" -match 'status=429\s|"status":429[,}]' }).Count -ne 2) { $complete=$false }
        }
        if ($complete) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $complete) { throw '429 请求应只到达 Nginx 和应用网关' }
    Write-Host 'PASS: 429 请求有 TraceId，完成日志仅出现在入口和应用网关'
    Write-Host '限流验收通过。测试会话将清理，计数自然过期。'
} finally {
    try {
        Remove-LabSession -Headers $first -BaseUrl $BaseUrl
        Remove-LabSession -Headers $second -BaseUrl $BaseUrl
    } finally { Pop-Location }
}
