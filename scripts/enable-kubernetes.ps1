#requires -Version 7.0
# 仅适用于本机 Docker Desktop。保留原设置备份，不执行 reset/purge。
$ErrorActionPreference = 'Stop'
$settingsFile = Join-Path $env:APPDATA 'Docker/settings-store.json'
if (-not (Test-Path -LiteralPath $settingsFile)) { throw '未找到 Docker Desktop settings-store.json' }
$settings = Get-Content -Raw -LiteralPath $settingsFile | ConvertFrom-Json -AsHashtable
if ($settings.KubernetesEnabled -eq $true) {
    Write-Host 'Docker Desktop 已设置启用 Kubernetes。'
    return
}
docker desktop stop
if ($LASTEXITCODE -ne 0) { throw '停止 Docker Desktop 失败，未修改设置' }
# Desktop 退出后重新读取，避免覆盖退出时保存的设置。
$settings = Get-Content -Raw -LiteralPath $settingsFile | ConvertFrom-Json -AsHashtable
$backup = "$settingsFile.novacloud-$(Get-Date -Format yyyyMMddHHmmss).bak"
Copy-Item -LiteralPath $settingsFile -Destination $backup
$settings.KubernetesEnabled = $true
$settings | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $settingsFile -Encoding utf8NoBOM
docker desktop start
if ($LASTEXITCODE -ne 0) { throw '设置已保存，请启动 Docker Desktop 完成 Kubernetes 初始化' }
Write-Host '已启用 Kubernetes，并在 Docker 设置目录保留原设置备份。首次启动需要下载集群镜像。'
