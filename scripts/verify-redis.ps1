#requires -Version 7.0
param([switch]$Restart, [ValidateSet('Compose','Kubernetes')][string]$Runtime = 'Compose')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/container-runtime.ps1"
Push-Location (Split-Path $PSScriptRoot -Parent)
function Invoke-LabRedis([string[]]$CommandArgs) {
    $reply = @(Invoke-LabContainer redis (@('sh','-c','REDISCLI_AUTH="$REDIS_PASSWORD" exec redis-cli --raw "$@"','redis-cli') + $CommandArgs))
    if ($LASTEXITCODE -ne 0) { throw 'Redis 命令执行失败' }
    return $reply
}
$key = 'lab:verify:' + [Guid]::NewGuid().ToString('N')
try {
    $unauthenticated = @(Invoke-LabContainer redis @('redis-cli','ping'))
    if ($LASTEXITCODE -ne 0 -or ($unauthenticated -join '') -notmatch 'NOAUTH') { throw 'Redis 必须拒绝未认证连接' }
    if ((Invoke-LabRedis -CommandArgs @('PING')) -ne 'PONG') { throw 'Redis PING 失败' }
    Write-Host 'PASS: 未认证连接被拒绝，认证连接 PING 成功'
    if (@(Invoke-LabRedis -CommandArgs @('CONFIG','GET','appendonly'))[1] -ne 'yes') { throw 'AOF 未启用' }
    if (@(Invoke-LabRedis -CommandArgs @('CONFIG','GET','appendfsync'))[1] -ne 'everysec') { throw 'AOF 策略不符' }
    if (@(Invoke-LabRedis -CommandArgs @('CONFIG','GET','maxmemory-policy'))[1] -ne 'noeviction') { throw '内存策略不符' }
    Write-Host 'PASS: AOF everysec 和 noeviction 配置生效'
    if ((Invoke-LabRedis -CommandArgs @('SET',$key,'redis-ok','EX','3')) -ne 'OK') { throw 'Redis 写入失败' }
    if ((Invoke-LabRedis -CommandArgs @('GET',$key)) -ne 'redis-ok') { throw 'Redis 读取失败' }
    $ttl = [long](Invoke-LabRedis -CommandArgs @('PTTL',$key))
    if ($ttl -le 0 -or $ttl -gt 3000) { throw 'Redis TTL 不符' }
    $deadline = [DateTime]::UtcNow.AddSeconds(6)
    do {
        $exists = Invoke-LabRedis -CommandArgs @('EXISTS',$key)
        if ($exists -eq '0') { break }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($exists -ne '0') { throw '临时 key 没有按时过期' }
    Write-Host 'PASS: Redis 读写和 TTL 过期验证通过'
    if ($Restart) {
        if ((Invoke-LabRedis -CommandArgs @('SET',$key,'restart-ok','EX','120')) -ne 'OK') { throw '准备重启样本失败' }
        try {
            Set-LabComponent redis Restart
            if ($LASTEXITCODE -ne 0) { throw 'Redis 重启失败' }
        } finally {
            Set-LabComponent redis Start
            if ($LASTEXITCODE -ne 0) { throw 'Redis 恢复健康失败' }
        }
        if ((Invoke-LabRedis -CommandArgs @('GET',$key)) -ne 'restart-ok') { throw '重启后样本数据丢失' }
        Write-Host 'PASS: Redis 正常重启后保留测试数据'
    }
    # 这是运行中的 Java 服务通过 Lettuce 访问 Redis 的健康结果，不只是 TCP 端口检查。
    $health = @(Invoke-LabContainer platform-service @('curl','-fsS','http://localhost:8080/actuator/health/redis'))
    if ($LASTEXITCODE -ne 0 -or (($health -join '') | ConvertFrom-Json).status -ne 'UP') { throw '中台 Java Redis 健康检查失败' }
    Write-Host 'PASS: 中台 Java 服务的 Redis 健康状态为 UP'
} finally {
    try { Invoke-LabRedis -CommandArgs @('DEL',$key) | Out-Null } finally { Pop-Location }
}
