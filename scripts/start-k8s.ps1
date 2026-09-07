#requires -Version 7.0
param([switch]$FreshData, [switch]$SkipVerify)
$ErrorActionPreference = 'Stop'
$Runtime = 'Kubernetes'
. "$PSScriptRoot/container-runtime.ps1"
$projectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $projectRoot
function Invoke-Kubectl([string[]]$Arguments) {
    kubectl --context docker-desktop @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'kubectl 操作失败，请检查上方非敏感输出' }
}
function Set-LabSecret([string]$Namespace,[string]$Name,[string[]]$Keys) {
    $data = @{}
    foreach ($key in $Keys) {
        if (-not $credentials[$key]) { throw ".env 缺少 $key，请先运行 init-env.ps1" }
        $data[$key] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($credentials[$key]))
    }
    $existingText = @(kubectl --context docker-desktop -n $Namespace get secret $Name --ignore-not-found -o json 2>$null)
    if ($LASTEXITCODE -ne 0) { throw '读取已有 Secret 失败' }
    if ($existingText.Count -gt 0) {
        $existing = ($existingText -join "`n") | ConvertFrom-Json -AsHashtable
        foreach ($key in $Keys) {
            if ($existing.data[$key] -cne $data[$key]) { throw "$Name 与 .env 不一致；停止部署，避免密码与已有数据卷不一致。请单独处理密码轮换。" }
        }
    }
    $secret = @{apiVersion='v1';kind='Secret';metadata=@{name=$Name;namespace=$Namespace};type='Opaque';data=$data}
    # 只输出资源名；失败时也不把 API 响应中可能包含的 Secret 正文写入日志。
    $result = @($secret | ConvertTo-Json -Depth 10 | kubectl --context docker-desktop apply --server-side --field-manager=novacloud-lab -f - 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "应用 $Namespace/$Name 失败（凭据输出已抑制）" }
    Write-Host "Secret 已就绪：$Namespace/$Name"
}
function Set-FileConfig([string]$Name,[string[]]$Files) {
    $arguments = @('--context','docker-desktop','-n','novacloud-app','create','configmap',$Name,'--dry-run=client','-o','json') + $Files
    $json = @(kubectl @arguments)
    if ($LASTEXITCODE -ne 0) { throw "生成 $Name 失败" }
    $json | kubectl --context docker-desktop apply -f -
    if ($LASTEXITCODE -ne 0) { throw "应用 $Name 失败" }
}
function Wait-Component([string]$Name) {
    Invoke-Kubectl @('-n',(Get-LabNamespace $Name),'rollout','status',"deployment/$Name",'--timeout=360s')
}
try {
    Invoke-Kubectl @('--request-timeout=15s','get','nodes')
    Invoke-Kubectl @('wait','--for=condition=Ready','node/docker-desktop','--timeout=60s')
    foreach ($module in @('app-gateway','app-service','platform-gateway','platform-service')) {
        docker image inspect "novacloud-lab/${module}:0.1.0" --format '{{.Id}}' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "缺少 $module 镜像，请先运行 scripts/start.ps1 完成构建。" }
    }
    & "$PSScriptRoot/init-env.ps1"
    $credentials = @{}
    foreach ($line in Get-Content -LiteralPath '.env') {
        if ($line -match '^([A-Z_]+)=(.*)$') { $credentials[$Matches[1]]=$Matches[2] }
    }
    Invoke-Kubectl @('apply','-f','infra/kubernetes/namespaces.yaml')
    Set-LabSecret 'novacloud-infra' 'mysql-credentials' @('MYSQL_PASSWORD','MYSQL_ROOT_PASSWORD')
    foreach ($namespace in @('novacloud-infra','novacloud-app','novacloud-platform')) {
        Set-LabSecret $namespace 'redis-credentials' @('REDIS_PASSWORD')
    }
    Set-LabSecret 'novacloud-platform' 'platform-credentials' @('MYSQL_PASSWORD','REDIS_PASSWORD','DEMO_PASSWORD')
    Invoke-Kubectl @('apply','-f','infra/kubernetes/java-config.yaml')
    Set-FileConfig 'nginx-config' @('--from-file=nginx.conf=infra/nginx/nginx.conf')
    Set-FileConfig 'frontend' @('--from-file=frontend/index.html','--from-file=frontend/app.js','--from-file=frontend/styles.css')
    foreach ($service in @('mysql','redis','nacos')) { Invoke-Kubectl @('apply','-f',"infra/kubernetes/$service.yaml") }
    foreach ($service in @('mysql','redis','nacos')) { Wait-Component $service }
    # 只给没有任何业务表的目标导入；绝不覆盖已有 Kubernetes 数据库。
    $tableCount = Invoke-LabContainer mysql @('sh','-c','MYSQL_PWD="$MYSQL_PASSWORD" mysql -ulab -N -B -D novacloud -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE()"')
    if ([int]$tableCount -eq 0) {
        if ($FreshData) {
            $sql = Get-Content -Raw -LiteralPath 'infra/mysql/001-init.sql'
            Write-Host '初始化独立演示数据库（FreshData）；不复制 Compose 数据。'
        } else {
            $sourceId = @(docker compose ps -a -q mysql)
            if ($LASTEXITCODE -ne 0 -or $sourceId.Count -ne 1) { throw '未找到原 Compose MySQL；如需全新实验数据，请明确使用 -FreshData。' }
            docker compose up -d --wait --wait-timeout 120 mysql
            if ($LASTEXITCODE -ne 0) { throw '原 Compose MySQL 未恢复健康，未开始复制。' }
            # Dump 仅留在内存中，不打印账号哈希，不在命令行传密码。
            $dump = @(docker compose exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysqldump -ulab --single-transaction --no-tablespaces --set-gtid-purged=OFF novacloud')
            if ($LASTEXITCODE -ne 0 -or $dump.Count -eq 0) { throw '读取 Compose 数据失败；启动原 MySQL 后重试，或明确使用 -FreshData 创建独立演示数据。' }
            $sql = $dump -join "`n"
            Write-Host '将 Compose novacloud 数据库逻辑复制到空 Kubernetes 数据库。'
        }
        Invoke-LabContainer mysql @('sh','-c','MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -ulab -D novacloud') -InputText $sql | Out-Null
        $sql = $null; $dump = $null
    } else { Write-Host 'Kubernetes 数据库已有业务表，保留现有数据，不重复导入。' }
    & "$PSScriptRoot/k8s-forward.ps1" -Service nacos
    & "$PSScriptRoot/init-nacos.ps1" -NacosUrl 'http://127.0.0.1:28848/nacos'
    foreach ($service in @('platform-service','platform-gateway','app-service','app-gateway','nginx')) {
        Invoke-Kubectl @('apply','-f',"infra/kubernetes/$service.yaml")
        # 同一镜像标签、环境变量和 subPath 配置不会自动触发更新，主动刷新 Pod。
        Invoke-Kubectl @('-n',(Get-LabNamespace $service),'rollout','restart',"deployment/$service")
        Wait-Component $service
    }
    & "$PSScriptRoot/k8s-forward.ps1" -Service nginx
    if (-not $SkipVerify) { & "$PSScriptRoot/verify-k8s.ps1" }
    Write-Host 'Kubernetes 已启动。工作台 http://127.0.0.1:28080；Nacos http://127.0.0.1:28848/nacos'
} finally { $credentials=$null; Pop-Location }
