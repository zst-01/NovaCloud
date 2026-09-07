param([string]$NacosUrl = 'http://127.0.0.1:18848/nacos')
$ErrorActionPreference = 'Stop'
$base = "$NacosUrl/v1/console/namespaces"
$existing = Invoke-RestMethod $base -TimeoutSec 10
foreach ($id in @('application','platform')) {
    if ($existing.data.namespace -notcontains $id) {
        $created = Invoke-RestMethod $base -Method Post -Body @{customNamespaceId=$id; namespaceName=$id; namespaceDesc="NovaCloud lab $id layer"} -TimeoutSec 10
        if ($created -ne $true -and $created -ne 'true') { throw "创建命名空间失败: $id" }
    }
    Write-Host "Nacos 命名空间已就绪: $id"
}
