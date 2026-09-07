#requires -Version 7.0
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:18080'
$page=Invoke-WebRequest $base -SkipHttpErrorCheck
if ($page.StatusCode -ne 200 -or $page.Content -notmatch '工单工作台') { throw '首页尚未提供工单工作台' }
foreach ($asset in @('app.js','styles.css')) {
    $r=Invoke-WebRequest "$base/$asset" -SkipHttpErrorCheck
    if ($r.StatusCode -ne 200) { throw "静态资源不可用: $asset" }
}
$missing=Invoke-WebRequest "$base/missing" -SkipHttpErrorCheck
if ($missing.StatusCode -ne 404) { throw '未知路径应保持 404' }
Write-Host 'PASS: 首页与静态资源可用，未知路径保持 404'
