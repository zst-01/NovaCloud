param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & "$PSScriptRoot/init-env.ps1"
    docker compose config --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Compose 配置检查失败' }
    # Java 集成测试需要连接本项目的真实 Redis，因此先启动基础设施。
    docker compose up -d --wait --wait-timeout 240 mysql nacos redis
    if ($LASTEXITCODE -ne 0) { throw '基础组件未就绪' }
    & "$PSScriptRoot/init-nacos.ps1"
    if (-not $SkipBuild) {
        docker compose --profile build run --rm -e REDIS_INTEGRATION=true builder
        if ($LASTEXITCODE -ne 0) { throw 'Java 构建或测试失败' }
        docker compose build
        if ($LASTEXITCODE -ne 0) { throw 'Java 镜像构建失败' }
    }
    docker compose up -d --wait --wait-timeout 420
    if ($LASTEXITCODE -ne 0) { throw '服务启动失败，请查看 docker compose logs' }
    # Java 容器重建后地址可能变化，同时重新加载挂载的 Nginx 配置。
    docker compose exec -T nginx nginx -t
    if ($LASTEXITCODE -ne 0) { throw 'Nginx 配置检查失败' }
    docker compose exec -T nginx nginx -s reload
    if ($LASTEXITCODE -ne 0) { throw 'Nginx 配置重载失败' }
    & "$PSScriptRoot/verify.ps1"
    & "$PSScriptRoot/verify-ui.ps1"
    & "$PSScriptRoot/verify-trace.ps1"
    & "$PSScriptRoot/verify-redis.ps1"
    & "$PSScriptRoot/verify-auth.ps1"
    & "$PSScriptRoot/verify-rate.ps1"
} finally { Pop-Location }
