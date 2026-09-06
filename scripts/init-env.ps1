#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$envFile = Join-Path (Split-Path $PSScriptRoot -Parent) '.env'
if (-not (Test-Path -LiteralPath $envFile)) {
    $mysqlPassword = [Guid]::NewGuid().ToString('N')
    $rootPassword = [Guid]::NewGuid().ToString('N')
    "MYSQL_PASSWORD=$mysqlPassword`nMYSQL_ROOT_PASSWORD=$rootPassword" | Set-Content -LiteralPath $envFile -Encoding utf8
    Write-Host '已生成本地数据库凭据。'
}
if (-not (Select-String -LiteralPath $envFile -Pattern '^REDIS_PASSWORD=' -Quiet)) {
    $redisPassword = [Guid]::NewGuid().ToString('N')
    "`nREDIS_PASSWORD=$redisPassword" | Add-Content -LiteralPath $envFile -Encoding utf8
    Write-Host '已添加 Redis 随机密码，保留已有配置，凭据不输出到日志。'
}
if (-not (Select-String -LiteralPath $envFile -Pattern '^DEMO_PASSWORD=' -Quiet)) {
    "`nDEMO_PASSWORD=$([Guid]::NewGuid().ToString('N'))" | Add-Content -LiteralPath $envFile -Encoding utf8
    Write-Host '已添加演示账号随机密码，凭据不输出到日志。'
}
