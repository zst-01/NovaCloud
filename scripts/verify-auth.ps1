#requires -Version 7.0
param([string]$BaseUrl = 'http://127.0.0.1:18080', [switch]$IncludeFailure)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/auth-session.ps1"
Push-Location (Split-Path $PSScriptRoot -Parent)
$demo = $null
$observer = $null
$expiring = $null
function Assert-Status($Response, [int]$Status, [string]$Label) {
    if ($Response.StatusCode -ne $Status) { throw "$Label 期望 $Status，实际 $($Response.StatusCode)" }
    if (@($Response.Headers['X-Trace-Id'])[0] -cnotmatch '^[0-9a-f]{32}$') { throw "$Label 缺少 TraceId" }
    Write-Host "PASS: $Label ($Status)"
}
function Invoke-SessionRedis($Headers, [string]$Operation) {
    # token 通过标准输入传递，不出现在命令参数和输出中；只操作本脚本创建的会话。
    $token = $Headers.Authorization.Substring(7)
    if ($Operation -eq 'TTL') {
        $result = @($token | docker compose exec -T redis sh -c 'token=$(tr -d "\r\n"); REDISCLI_AUTH="$REDIS_PASSWORD" exec redis-cli --raw TTL "lab:session:$token"')
    } else {
        $result = @($token | docker compose exec -T redis sh -c 'token=$(tr -d "\r\n"); REDISCLI_AUTH="$REDIS_PASSWORD" exec redis-cli --raw EXPIRE "lab:session:$token" 1')
    }
    if ($LASTEXITCODE -ne 0) { throw '测试会话 TTL 操作失败' }
    return [long]($result -join '')
}
try {
    $r = Invoke-LabWebRequest "$BaseUrl/api/tickets/1" -SkipHttpErrorCheck -TimeoutSec 15
    Assert-Status $r 401 '未登录查询被拒绝'
    $deniedTrace = @($r.Headers['X-Trace-Id'])[0]
    $r = Invoke-LabWebRequest "$BaseUrl/api/tickets/1" -Headers @{'X-User-Id'='demo';'X-User-Roles'='admin';Authorization='Bearer invalid'} -SkipHttpErrorCheck
    Assert-Status $r 401 '伪造身份和无效 token 被拒绝'
    $r = Invoke-LabWebRequest "$BaseUrl/api/auth/login" -Method Post -ContentType 'application/json' -Body '{"username":"demo","password":"deliberately-wrong"}' -SkipHttpErrorCheck
    Assert-Status $r 401 '错误密码被拒绝'
    $r = Invoke-LabWebRequest "$BaseUrl/api/auth/login" -Method Post -ContentType 'application/json' -Body '{}' -SkipHttpErrorCheck
    Assert-Status $r 400 '缺失登录字段被拒绝'
    $demo = New-LabSession -BaseUrl $BaseUrl
    $observer = New-LabSession -BaseUrl $BaseUrl -Username observer
    $ttl = Invoke-SessionRedis $demo 'TTL'
    if ($ttl -le 1700 -or $ttl -gt 1800) { throw '新会话 TTL 不符合 30 分钟约定' }
    Write-Host 'PASS: 登录成功，真实 Redis 会话 TTL 为 30 分钟'
    $r = Invoke-LabWebRequest "$BaseUrl/api/auth/me" -Headers $demo
    Assert-Status $r 200 '查询当前用户'
    $me = $r.Content | ConvertFrom-Json
    if ($me.username -ne 'demo' -or $me.permissions -notcontains 'ticket:read') { throw '当前用户信息不符' }
    $r = Invoke-LabWebRequest "$BaseUrl/api/tickets/1" -Headers $demo
    Assert-Status $r 200 '登录后查询工单'
    if (($r.Content | ConvertFrom-Json).id -ne 1) { throw '工单返回不符' }
    $r = Invoke-LabWebRequest "$BaseUrl/api/tickets/1" -Headers ($observer + @{'X-User-Roles'='admin'}) -SkipHttpErrorCheck
    Assert-Status $r 403 '无查询权限账号不能靠身份头提权'
    foreach ($path in @('/api/%74ickets/1','/api/tickets;x=y/1')) {
        $r = Invoke-LabWebRequest "$BaseUrl$path" -Headers $observer -SkipHttpErrorCheck
        Assert-Status $r 403 '特殊路径不能绕过权限'
    }
    foreach ($service in @('platform-gateway','platform-service')) {
        $status = docker compose exec -T $service curl -sS -o /dev/null -w '%{http_code}' http://localhost:8080/api/tickets/1
        if ($LASTEXITCODE -ne 0 -or "$status" -ne '401') { throw "$service 直接访问未拒绝匿名请求" }
        $status = "Authorization: $($observer.Authorization)" | docker compose exec -T $service curl -sS -H '@-' -o /dev/null -w '%{http_code}' http://localhost:8080/api/tickets/1
        if ($LASTEXITCODE -ne 0 -or "$status" -ne '403') { throw "$service 直接访问未执行权限检查" }
        Write-Host "PASS: $service 直接访问也校验会话及权限"
        $status = "Authorization: $($observer.Authorization)" | docker compose exec -T $service curl --path-as-is -sS -H '@-' -o /dev/null -w '%{http_code}' http://localhost:8080/actuator/health/../../api/tickets/1
        if ($LASTEXITCODE -ne 0 -or "$status" -notin @('400','403')) { throw "$service 健康路径前缀绕过检查失败" }
    }
    $expiring = New-LabSession -BaseUrl $BaseUrl
    if ((Invoke-SessionRedis $expiring 'EXPIRE') -ne 1) { throw '缩短测试会话 TTL 失败' }
    Start-Sleep -Seconds 2
    $r = Invoke-LabWebRequest "$BaseUrl/api/auth/me" -Headers $expiring -SkipHttpErrorCheck
    Assert-Status $r 401 '真实 Redis 会话过期后失效'
    if ($IncludeFailure) {
        try {
            docker compose stop redis
            if ($LASTEXITCODE -ne 0) { throw '停止 Redis 失败' }
            $r = Invoke-LabWebRequest "$BaseUrl/api/tickets/1" -Headers $demo -SkipHttpErrorCheck -TimeoutSec 20
            Assert-Status $r 503 'Redis 停机时不放行'
        } finally {
            docker compose up -d --wait --wait-timeout 180
            if ($LASTEXITCODE -ne 0) { throw '故障实验后服务未恢复健康' }
        }
        $r = Invoke-LabWebRequest "$BaseUrl/api/tickets/1" -Headers $demo -TimeoutSec 20
        Assert-Status $r 200 'Redis 恢复后原会话可查询'
    }
    $r = Invoke-LabWebRequest "$BaseUrl/api/auth/logout" -Method Post -Headers $demo
    Assert-Status $r 200 '退出登录'
    $r = Invoke-LabWebRequest "$BaseUrl/api/tickets/1" -Headers $demo -SkipHttpErrorCheck
    Assert-Status $r 401 '退出后原 token 立即失效'
    if ((Invoke-SessionRedis $demo 'TTL') -ne -2) { throw '退出后会话 key 未删除' }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $lines = @(docker compose logs --since 5m --no-color nginx app-gateway app-service platform-gateway platform-service 2>&1)
        if ($LASTEXITCODE -ne 0) { throw '读取鉴权日志失败' }
        $denied = @($lines | Where-Object { "$_".Contains($deniedTrace) -and "$_" -match 'request_complete' })
        if ($denied.Count -ge 2) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($denied.Count -ne 2 -or @($denied | Where-Object { "$_" -match '^(nginx|app-gateway)-\d+\s+\|' }).Count -ne 2) {
        throw '匿名拒绝请求应只在 Nginx 和应用网关留下完成日志'
    }
    $logText = $lines -join "`n"
    $passwordLine = Get-Content -LiteralPath '.env' | Where-Object { $_ -match '^DEMO_PASSWORD=' } | Select-Object -First 1
    foreach ($secret in @($demo.Authorization.Substring(7), $observer.Authorization.Substring(7), $expiring.Authorization.Substring(7), $passwordLine.Substring(14))) {
        if ($logText.Contains($secret)) { throw '运行日志包含测试凭据，请检查日志记录边界' }
    }
    Write-Host 'PASS: 拒绝请求日志链路正确，日志未包含本次 token 或演示密码'
    Write-Host '登录鉴权验收通过；未输出密码或 token。'
} finally {
    try {
        Remove-LabSession -Headers $demo -BaseUrl $BaseUrl
        Remove-LabSession -Headers $observer -BaseUrl $BaseUrl
        Remove-LabSession -Headers $expiring -BaseUrl $BaseUrl
    } finally { Pop-Location }
}
