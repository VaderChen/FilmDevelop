param([string]$Build=$PSScriptRoot)
. (Join-Path $PSScriptRoot 'windows-smoke-common.ps1') -Build $Build

# CPU 備援與 GPU 各自使用獨立程序；以沒有快取的同一路徑作為像素基準。
$cpu=Join-Path $output 'cpu'
New-Item -ItemType Directory -Path $cpu | Out-Null
foreach($name in @('filmdevelop-engine.exe','neutral-recipe.json','style-catalog.json','film-data')) {
 Copy-Item -LiteralPath (Join-Path $Build $name) -Destination $cpu -Recurse
}
Get-ChildItem -LiteralPath $Build -Filter *.dll | Where-Object Name -NotIn @('libPhotoCompute.dll','fault-compute.dll') | Copy-Item -Destination $cpu
$caps=Invoke-Engine 'capabilities' @{}
Require ($caps.kind -eq 'result') '無法偵測後端'
$routes=@('cpu')
if($caps.payload.computeBackends -contains 'vulkan'){$routes+='vulkan'}
$sizes=@(96,160,96,240,160,96,0,96)
$hits=@($false,$false,$true,$false,$true,$false,$true,$true)
foreach($route in $routes) {
 $executable=if($route -eq 'cpu'){Join-Path $cpu 'filmdevelop-engine.exe'}else{Join-Path $Build 'filmdevelop-engine.exe'}
 $relative=$executable.Substring($Build.Length+1)
 $process=Start-Native $relative '--preview-session'
 try {
  for($index=0;$index -lt $sizes.Count;$index++) {
   $size=$sizes[$index]
   Check ($route+' 尺寸切換、淘汰與獨立輸出比對：'+$index+' / '+$size) {
    $job=New-Job 'system' ($index*.1) 'png' 16
    $job.previewMaxPixel=$(if($size -eq 0){320}else{$size});$job.output.maxPixel=$size
    $job.policy.fullResolution=($size -eq 0)
    $job.recipe.adjustment.brightness=$index*3
    $result=Request $process 'preview' $job
    Require ($result.kind -eq 'result') ($result.error|ConvertTo-Json -Compress)
    Require ($result.payload.computeRoute -eq $route) '沒有使用預期的計算路徑'
    Require ($result.payload.timing.sourceCacheHit -eq ($index -gt 0)) '解碼來源快取狀態不符'
    Require ($result.payload.timing.processingCacheHit -eq $hits[$index]) '兩種尺寸的快取或淘汰狀態不符'
    $hash=(Get-FileHash -LiteralPath $job.output.path).Hash
    $job.output.path=Join-Path $output ([guid]::NewGuid().ToString('N')+'.png')
    $fresh=Start-Native $relative
    try {
     $reference=Request $fresh 'preview' $job
     Require ($reference.kind -eq 'result') ($reference.error|ConvertTo-Json -Compress)
     Require ($reference.payload.width -eq $result.payload.width -and $reference.payload.height -eq $result.payload.height) '快取改變輸出尺寸'
     Require ($reference.payload.sourceImage -eq $result.payload.sourceImage) '原片比較被調整或尺寸快取污染'
     Require ($reference.payload.cropImage -eq $result.payload.cropImage) '編輯圖與獨立處理不同'
     Require ((Get-FileHash -LiteralPath $job.output.path).Hash -eq $hash) 'PNG16 與獨立處理不同'
    } finally {$fresh.StandardInput.Close();if(!$fresh.WaitForExit(5000)){$fresh.Kill()};$fresh.Dispose()}
    return @{size=$size;route=$route;timing=$result.payload.timing;imageSHA256=$hash}
   }
  }
 } finally {$process.StandardInput.Close();if(!$process.WaitForExit(5000)){$process.Kill()};$process.Dispose()}
}
$report=@{schema=1;finishedAtUTC=[DateTime]::UtcNow.ToString('o');checks=$results;passed=(@($results|Where-Object{!$_.passed}).Count -eq 0);output=$output}
$report|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $Build 'preview-cache-report.json') -Encoding UTF8
if(!$report.passed){exit 1}
