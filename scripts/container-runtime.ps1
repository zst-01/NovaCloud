# 公共验收适配层：HTTP 断言保持一致，只切换 exec/logs/故障操作的目标。
function Get-LabNamespace([string]$Service) {
    switch -Regex ($Service) {
        '^(nginx|app-gateway|app-service)$' { return 'novacloud-app' }
        '^platform-(gateway|service)$' { return 'novacloud-platform' }
        '^(mysql|redis|nacos)$' { return 'novacloud-infra' }
        default { throw "未知的 NovaCloud 组件: $Service" }
    }
}
function Invoke-LabContainer {
    param([string]$Service, [string[]]$Command, [string]$InputText)
    $hasInput = $PSBoundParameters.ContainsKey('InputText')
    if ($Runtime -eq 'Kubernetes') {
        $arguments = @('--context','docker-desktop','-n',(Get-LabNamespace $Service),'exec')
        if ($hasInput) { $arguments += '-i' }
        $arguments += @("deployment/$Service",'--') + $Command
        if ($hasInput) { $InputText | kubectl @arguments } else { kubectl @arguments }
    } else {
        if ($hasInput) { $InputText | docker compose exec -T $Service @Command }
        else { docker compose exec -T $Service @Command }
    }
    if ($LASTEXITCODE -ne 0) { throw "$Service 容器命令失败" }
}
function Get-LabLogs {
    param([string]$Since = '5m')
    $services = @('nginx','app-gateway','app-service','platform-gateway','platform-service')
    if ($Runtime -eq 'Kubernetes') {
        foreach ($service in $services) {
            $lines = @(kubectl --context docker-desktop -n (Get-LabNamespace $service) logs "deployment/$service" "--since=$Since" --tail=-1)
            if ($LASTEXITCODE -ne 0) { throw "读取 $service Kubernetes 日志失败" }
            # 保留现有验收用的组件前缀；仅用于单副本实验，不冒充真实 Pod 名。
            $lines | ForEach-Object { "$service-1 | $_" }
        }
    } else {
        docker compose logs "--since=$Since" --no-color @services
        if ($LASTEXITCODE -ne 0) { throw '读取 Compose 日志失败' }
    }
}
function Set-LabComponent {
    param([string]$Service, [ValidateSet('Stop','Start','Restart')][string]$Action)
    if ($Runtime -eq 'Kubernetes') {
        $namespace = Get-LabNamespace $Service
        if ($Action -eq 'Restart') {
            kubectl --context docker-desktop -n $namespace rollout restart "deployment/$Service"
        } else {
            $replicas = if ($Action -eq 'Stop') { 0 } else { 1 }
            kubectl --context docker-desktop -n $namespace scale "deployment/$Service" "--replicas=$replicas"
        }
        if ($LASTEXITCODE -ne 0) { throw "$Service $Action 失败" }
        if ($Action -ne 'Stop') {
            kubectl --context docker-desktop -n $namespace rollout status "deployment/$Service" --timeout=300s
            if ($LASTEXITCODE -ne 0) { throw "$Service 未恢复就绪" }
            if ($Service -in @('redis','mysql')) {
                $clients = if ($Service -eq 'redis') { @('app-gateway','platform-gateway','platform-service') } else { @('platform-service') }
                foreach ($client in $clients) {
                    $deadline = [DateTime]::UtcNow.AddSeconds(60)
                    do {
                        # Pod Ready 不代表其他 Pod 中的连接池已经重新连接到它。
                        $health = @(kubectl --context docker-desktop -n (Get-LabNamespace $client) exec "deployment/$client" -- curl -fsS --max-time 5 http://localhost:8080/actuator/health 2>$null)
                        $healthy = $LASTEXITCODE -eq 0 -and (($health -join '') | ConvertFrom-Json).status -eq 'UP'
                        if ($healthy) { break }
                        Start-Sleep -Seconds 1
                    } while ([DateTime]::UtcNow -lt $deadline)
                    if (-not $healthy) { throw "$client 尚未恢复与 $Service 的连接" }
                }
                Write-Host "PASS: 依赖 $Service 的 Java 服务已恢复健康"
            }
        } else {
            kubectl --context docker-desktop -n $namespace wait --for=delete pod -l "app=$Service" --timeout=90s
            if ($LASTEXITCODE -ne 0) { throw "$Service 未停止" }
        }
    } else {
        if ($Action -eq 'Stop') { docker compose stop $Service }
        elseif ($Action -eq 'Restart') {
            docker compose restart $Service
            if ($LASTEXITCODE -ne 0) { throw "$Service 重启失败" }
            docker compose up -d --wait --wait-timeout 180 $Service
        } elseif ($Service -eq 'redis') { docker compose up -d --wait --wait-timeout 180 }
        else { docker compose up -d --wait --wait-timeout 180 $Service }
        if ($LASTEXITCODE -ne 0) { throw "$Service $Action 失败" }
    }
}
