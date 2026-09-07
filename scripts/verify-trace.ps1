#requires -Version 7.0
param([string]$BaseUrl = 'http://127.0.0.1:18080', [switch]$IncludeFailure, [ValidateSet('Compose','Kubernetes')][string]$Runtime = 'Compose', [string]$NacosUrl = 'http://127.0.0.1:18848/nacos')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/container-runtime.ps1"
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    . "$PSScriptRoot/auth-session.ps1"
    $authHeaders = New-LabSession -BaseUrl $BaseUrl
    $samples = [System.Collections.Generic.List[object]]::new()
    foreach ($case in @(@{Id='1';Status=200}, @{Id='999999';Status=404}, @{Id='invalid';Status=400})) {
        $response = Invoke-LabWebRequest "$BaseUrl/api/tickets/$($case.Id)" -Headers ($authHeaders + @{'X-Trace-Id'='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}) -SkipHttpErrorCheck -TimeoutSec 20
        $trace = @($response.Headers['X-Trace-Id'])
        if ($trace.Count -ne 1 -or $trace[0] -cnotmatch '^[0-9a-f]{32}$') { throw '响应必须只有一个合法 X-Trace-Id' }
        if ($trace[0] -eq 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') { throw 'Nginx 未替换外部编号' }
        if ($response.StatusCode -ne $case.Status) { throw "非预期状态: $($response.StatusCode)" }
        $hops = if ($case.Status -eq 400) { @('nginx','app-gateway','app-service') } else { @('nginx','app-gateway','app-service','platform-gateway','platform-service') }
        $samples.Add(@{Trace=$trace[0];Status=$case.Status;Hops=$hops})
    }
    # 在入口和网关提前结束的请求，也应留下相应环节的编号和错误日志。
    foreach ($case in @(@{Path='/missing';Hops=@('nginx')}, @{Path='/api/missing';Hops=@('nginx','app-gateway')})) {
        $r = Invoke-LabWebRequest "$BaseUrl$($case.Path)" -Headers $authHeaders -SkipHttpErrorCheck -TimeoutSec 20
        if ($r.StatusCode -ne 404) { throw '不存在的入口或网关路由应返回 404' }
        $samples.Add(@{Trace=@($r.Headers['X-Trace-Id'])[0];Status=404;Hops=$case.Hops})
    }
    # 并发请求必须分别得到不同编号；后面检查每一条编号在五层的完整日志。
    $helperPath = "$PSScriptRoot/auth-session.ps1"
    $parallel = 1..6 | ForEach-Object -Parallel {
        . $using:helperPath
        $r = Invoke-LabWebRequest "$using:BaseUrl/api/tickets/1" -Headers $using:authHeaders -TimeoutSec 20
        @{Trace=@($r.Headers['X-Trace-Id'])[0];Status=[int]$r.StatusCode;Hops=@('nginx','app-gateway','app-service','platform-gateway','platform-service')}
    } -ThrottleLimit 6
    foreach ($sample in $parallel) { $samples.Add($sample) }
    if ($IncludeFailure) {
        try {
            Set-LabComponent platform-gateway Stop
            if ($LASTEXITCODE -ne 0) { throw '停止中台网关失败' }
            $r = Invoke-LabWebRequest "$BaseUrl/api/tickets/1" -Headers $authHeaders -SkipHttpErrorCheck -TimeoutSec 20
            if ($r.StatusCode -notin @(502,504)) { throw "故障应返回 502 或 504，实际 $($r.StatusCode)" }
            $samples.Add(@{Trace=@($r.Headers['X-Trace-Id'])[0];Status=[int]$r.StatusCode;Hops=@('nginx','app-gateway','app-service')})
        } finally {
            Set-LabComponent platform-gateway Start
            if ($LASTEXITCODE -ne 0) { throw '恢复中台网关失败' }
        }
    }
    if (@($samples.Trace | Select-Object -Unique).Count -ne $samples.Count) { throw '不同请求出现相同或缺失的 TraceId' }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $lines = @(Get-LabLogs)
        if ($LASTEXITCODE -ne 0) { throw '无法读取 Docker 日志' }
        $pending = @()
        foreach ($sample in $samples) {
            if ($sample.Trace -cnotmatch '^[0-9a-f]{32}$') { throw 'TraceId 格式不合法' }
            foreach ($hop in $sample.Hops) {
                $completionLines = @($lines | Where-Object { "$_" -match "^$hop-\d+\s+\|" -and "$_".Contains($sample.Trace) -and ("$_" -match 'request_complete|"event":"request_complete"') })
                if ($completionLines.Count -ne 1) { $pending += "$hop / $($sample.Trace) completion count=$($completionLines.Count)"; continue }
                $statusPattern = if ($hop -eq 'nginx') { '"status":' + $sample.Status + '[,}]' } else { 'status=' + $sample.Status + '(\s|$)' }
                if ("$($completionLines[0])" -notmatch $statusPattern) { throw "日志状态不符: $($completionLines[0])" }
                $durationPattern = if ($hop -eq 'nginx') { '"durationSec":[0-9.]+' } else { 'durationMs=\d+' }
                if ("$($completionLines[0])" -notmatch $durationPattern) { throw "日志缺少耗时: $($completionLines[0])" }
            }
        }
        if ($pending.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($pending.Count -gt 0) { throw "日志验证未通过: $($pending -join '; ')" }
    foreach ($sample in $samples) { Write-Host "PASS traceId=$($sample.Trace) status=$($sample.Status) hops=$($sample.Hops -join ',')" }
    Write-Host "TraceId 验收通过：$($samples.Count) 个请求，包括 6 个并发请求。"
    if ($IncludeFailure) { & "$PSScriptRoot/verify.ps1" -BaseUrl $BaseUrl -NacosUrl $NacosUrl }
} finally { try { Remove-LabSession -Headers $authHeaders -BaseUrl $BaseUrl } finally { Pop-Location } }
