#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$base = 'http://127.0.0.1:28080'
$nacos = 'http://127.0.0.1:28848/nacos'
. "$PSScriptRoot/container-runtime.ps1"
$services = @('mysql','redis','nacos','platform-service','platform-gateway','app-service','app-gateway','nginx')
foreach ($service in $services) {
    $deployment = kubectl --context docker-desktop -n (Get-LabNamespace $service) get deployment $service -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $deployment.status.readyReplicas -ne 1) { throw "$service Deployment 尚未就绪" }
}
$claims = kubectl --context docker-desktop -n novacloud-infra get pvc -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or @($claims.items | Where-Object { $_.status.phase -eq 'Bound' }).Count -ne 3) { throw '三个数据卷尚未绑定' }
Write-Host 'PASS: docker-desktop 上 8 个 Deployment 就绪，3 个 PVC Bound'
# 除 HTTP 验收外，验证 Nacos 实例 IP 来自 Kubernetes Pod，防止误测 Compose。
foreach ($service in @('app-gateway','app-service','platform-gateway','platform-service')) {
    $pods = kubectl --context docker-desktop -n (Get-LabNamespace $service) get pods -l "app=$service" -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw '读取 Pod IP 失败' }
    $namespace = if ($service.StartsWith('app-')) { 'application' } else { 'platform' }
    $instances = Invoke-RestMethod "$nacos/v1/ns/instance/list?serviceName=$service&namespaceId=$namespace&healthyOnly=true" -TimeoutSec 10
    if (@($instances.hosts).Count -ne 1 -or $pods.items.status.podIP -notcontains $instances.hosts[0].ip) { throw "$service Nacos 实例与 Kubernetes Pod 不一致" }
}
Write-Host 'PASS: Nacos 注册的是 Kubernetes Pod 地址'
& "$PSScriptRoot/verify.ps1" -BaseUrl $base -NacosUrl $nacos
& "$PSScriptRoot/verify-ui.ps1" -BaseUrl $base
& "$PSScriptRoot/verify-trace.ps1" -BaseUrl $base -NacosUrl $nacos -Runtime Kubernetes
& "$PSScriptRoot/verify-redis.ps1" -Runtime Kubernetes
& "$PSScriptRoot/verify-auth.ps1" -BaseUrl $base -Runtime Kubernetes
& "$PSScriptRoot/verify-rate.ps1" -BaseUrl $base -Runtime Kubernetes
Write-Host 'Kubernetes 链路、页面、日志、Redis、登录鉴权、并发限流验收全部通过。'
