param([string]$BaseUrl = 'http://127.0.0.1:18080', [string]$NacosUrl = 'http://127.0.0.1:18848/nacos')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/auth-session.ps1"
$authHeaders = New-LabSession -BaseUrl $BaseUrl
try {
function Assert-Lab($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}
try { $response = Invoke-LabWebRequest "$BaseUrl/api/tickets/1" -Headers $authHeaders -TimeoutSec 15 } catch { throw "FAIL: 入口尚未提供完整查询能力: $($_.Exception.Message)" }
Assert-Lab ($response.StatusCode -eq 200) '入口返回 200'
$ticket = $response.Content | ConvertFrom-Json
Assert-Lab ($ticket.id -eq 1 -and $ticket.title -eq 'Demo after-sales ticket' -and $ticket.status -eq 'OPEN') '返回 MySQL 演示记录'
foreach ($hop in @('Nginx','App-Gateway','App-Service','Platform-Gateway','Platform-Service')) {
    Assert-Lab ($response.Headers["X-Lab-$hop"] -eq 'visited') "经过 $hop"
}
foreach ($case in @(@{Id='999999';Code=404},@{Id='invalid';Code=400})) {
    $r = Invoke-LabWebRequest "$BaseUrl/api/tickets/$($case.Id)" -Headers $authHeaders -SkipHttpErrorCheck -TimeoutSec 15
    Assert-Lab ($r.StatusCode -eq $case.Code) "ID=$($case.Id) 返回 $($case.Code)"
}
foreach ($ns in @(@{Id='application';Names=@('app-gateway','app-service')},@{Id='platform';Names=@('platform-gateway','platform-service')})) {
    $services = Invoke-RestMethod "$NacosUrl/v1/ns/service/list?pageNo=1&pageSize=100&namespaceId=$($ns.Id)" -TimeoutSec 10
    Assert-Lab ($services.count -eq 2) "$($ns.Id) 恰有两个服务"
    foreach ($name in $ns.Names) {
        Assert-Lab ($services.doms -contains $name) "$name 注册在 $($ns.Id)"
        $instances = Invoke-RestMethod "$NacosUrl/v1/ns/instance/list?serviceName=$name&namespaceId=$($ns.Id)&healthyOnly=true" -TimeoutSec 10
        Assert-Lab (@($instances.hosts).Count -eq 1 -and $instances.hosts[0].healthy) "$name 有一个健康实例"
    }
}
Write-Host '全部第一阶段链路检查通过。'
} finally { Remove-LabSession -Headers $authHeaders -BaseUrl $BaseUrl }
