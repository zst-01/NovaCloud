#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$Runtime = 'Kubernetes'
. "$PSScriptRoot/container-runtime.ps1"
& "$PSScriptRoot/k8s-forward.ps1" -Action Stop
foreach ($service in @('nginx','app-gateway','app-service','platform-gateway','platform-service','nacos','redis','mysql')) {
    Set-LabComponent $service Stop
}
Write-Host 'NovaCloud Kubernetes 工作负载已停止，PVC、配置和集群保留。恢复使用 scripts/start-k8s.ps1。'
