param([string]$Build=$PSScriptRoot)
. (Join-Path $PSScriptRoot 'windows-smoke-common.ps1') -Build $Build
$portrait=Join-Path $Build 'portrait.png'
$sourceHash=(Get-FileHash $portrait).Hash
Check 'Windows AI 執行環境安裝前置檢查' {
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Build 'Prerequisites\ensure-prerequisites.ps1') -CheckOnly
 Require ($LASTEXITCODE -eq 0) 'Microsoft 執行環境檢查未通過'
}
Check '真實人像分析含臉部亮度證據' {
 $job=New-Job;$job.input.path=$portrait
 $reply=Invoke-Engine 'analysis' @{input=$job.input;recipe=$job.recipe}
 Require ($reply.kind -eq 'result') ($reply.error|ConvertTo-Json -Compress)
 Require ($reply.payload.analysis -match 'Detected face-region median luminances:') '沒有辨識人像中的臉部'
 return $reply.payload.analysis
}
Check '真實主體與景深推論、參數套用與快取' {
 $job=New-Job 'vulkan' 0 'png' 16;$job.input.path=$portrait;$job.recipe.detectSubject=$true
 $process=Start-Native 'filmdevelop-engine.exe' '--preview-session'
 try {
  $base=Request $process 'preview' $job
  Require ($base.kind -eq 'result') ($base.error|ConvertTo-Json -Compress)
  Require $base.payload.subjectDetected '主體未被偵測'
  Require (!$base.payload.depthAvailable) '未要求散景仍執行景深推論'
  $baseHash=(Get-FileHash $job.output.path).Hash
  $job.output.path=Join-Path $output 'portrait-depth.png';$job.recipe.adjustment.backgroundBlur=85
  $blur=Request $process 'preview' $job
  Require ($blur.kind -eq 'result') ($blur.error|ConvertTo-Json -Compress)
  Require ($blur.payload.depthAvailable -and $blur.payload.subjectDetected) '景深或主體遺失'
  Require ($blur.payload.timing.sourceCacheHit -and $blur.payload.timing.subjectCacheHit) '來源或主體被重算'
  Require ((Get-FileHash $job.output.path).Hash -ne $baseHash) '散景未套用'
  $job.output.path=Join-Path $output 'portrait-edited.png';$job.recipe.adjustment.skinWhitening=70;$job.recipe.adjustment.skinSmoothing=75;$job.recipe.adjustment.skinWarmth=30;$job.recipe.adjustment.denoise=50
  $edit=Request $process 'preview' $job
  Require ($edit.kind -eq 'result') ($edit.error|ConvertTo-Json -Compress)
  Require ($edit.payload.timing.sourceCacheHit -and $edit.payload.timing.subjectCacheHit -and $edit.payload.timing.depthCacheHit) '編輯未重用來源或視覺快取'
  Require ($edit.payload.computeRoute -eq 'vulkan') '編輯未使用 Vulkan'
  return @{subject=$base.payload.timing;depth=$blur.payload.timing;edited=$edit.payload.timing;image=$job.output.path}
 } finally {$process.StandardInput.Close();if(!$process.WaitForExit(5000)){$process.Kill()};$process.Dispose()}
}
Check 'CPU 與 Vulkan 主體、景深、降噪數值一致' {
 return Run-Native 'photo_compute_semantics_verify.exe' ('"'+(Join-Path $Build 'film-data')+'" "'+(Join-Path $Build 'film.comp.spv')+'" "'+(Join-Path $Build 'style-catalog.json')+'"')
}
foreach($frame in @('whitePaperThin','whitePaperWide','whitePaperPolaroid','blackLine','filmStrip','cleanInset')) {
 Check ('外框預覽、匯出與重新解析：'+$frame) {
  $job=New-Job 'system' 0 'png' 16;$job.recipe.adjustment.frameEnabled=$true;$job.recipe.adjustment.frameStyle=$frame;$job.output.maxPixel=0
  $reply=Invoke-Engine 'preview' $job
  Require ($reply.kind -eq 'result') ($reply.error|ConvertTo-Json -Compress)
  $baseSize=Expected-ImageSize $job.input.path $job.previewMaxPixel
  Require ($reply.payload.width -gt $baseSize[0] -and $reply.payload.height -gt $baseSize[1] -and $reply.payload.outputWidth -gt $reply.payload.sourceWidth) '外框未增加畫布'
  $meta=Invoke-Engine 'metadata' @{path=$job.output.path}
  Require ($meta.kind -eq 'result' -and $meta.payload.PixelWidth -eq $reply.payload.width) '成品尺寸不一致'
  return @{width=$reply.payload.width;height=$reply.payload.height;file=$job.output.path}
 }
}
foreach($style in @('numeric','slash','compact','japanese')) {
 Check ('日期預覽及匯出：'+$style) {
  $job=New-Job 'system' 0 'png' 16;$job.preview=$false
  $before=Invoke-Engine 'render' $job;Require ($before.kind -eq 'result') ($before.error|ConvertTo-Json -Compress)
  $beforeHash=(Get-FileHash $job.output.path).Hash
  $job.output.path=Join-Path $output ('date-'+$style+'.png');$job.recipe.adjustment.dateEnabled=$true;$job.recipe.adjustment.dateStyle=$style
  $after=Invoke-Engine 'render' $job;Require ($after.kind -eq 'result') ($after.error|ConvertTo-Json -Compress)
  Require ((Get-FileHash $job.output.path).Hash -ne $beforeHash) '日期未繪製'
  Require ($after.payload.width -eq $before.payload.width -and $after.payload.height -eq $before.payload.height) '日期改變影像尺寸'
  return $job.output.path
 }
}
Check '缺少模型會回覆可處理錯誤，不會異常結束' {
 $reply=Invoke-Engine 'prepareRepair' @{path=(Join-Path $output 'missing-model')}
 Require ($reply.kind -eq 'error' -and $reply.error.message) '沒有收到模型錯誤'
}
Check '同路徑替換照片即使還原修改時間也會清除快取' {
 $copy=Join-Path $output 'replace.png';Copy-Item $portrait $copy
 $job=New-Job 'vulkan' 0 'png' 16;$job.input.path=$copy
 $process=Start-Native 'filmdevelop-engine.exe' '--preview-session'
 try {
  $first=Request $process 'preview' $job;Require ($first.kind -eq 'result') ($first.error|ConvertTo-Json -Compress)
  $time=(Get-Item $copy).LastWriteTimeUtc
  $next=Join-Path $output 'replacement.png';Copy-Item (Join-Path $Build '中文 橫向.jpg') $next
  Remove-Item $copy;Move-Item $next $copy;(Get-Item $copy).LastWriteTimeUtc=$time
  $job.output.path=Join-Path $output 'changed.png'
  $changed=Request $process 'preview' $job;Require ($changed.kind -eq 'result') ($changed.error|ConvertTo-Json -Compress)
  Require (!$changed.payload.timing.sourceCacheHit) '同路徑不同檔案誤用舊圖'
  Require ($changed.payload.sourceWidth -ne $first.payload.sourceWidth -or $changed.payload.sourceHeight -ne $first.payload.sourceHeight) '沒有重新解析照片'
  return $changed.payload.timing
 } finally {$process.StandardInput.Close();if(!$process.WaitForExit(5000)){$process.Kill()};$process.Dispose()}
}
Check 'RAW EXIF 不需要完成影像解碼' {
 $reply=Invoke-Engine 'metadata' @{path=(Join-Path $Build 'metadata.NEF')}
 Require ($reply.kind -eq 'result') ($reply.error|ConvertTo-Json -Compress)
 Require ($reply.payload.Make -match 'NIKON' -and $reply.payload.Model -and $reply.payload.FNumber -gt 0 -and $reply.payload.ISOSpeedRatings -gt 0) 'RAW 相機資訊不完整'
 return $reply.payload
}
Check '人像來源照片未被更改' {Require ((Get-FileHash $portrait).Hash -eq $sourceHash) '人像來源已改變'}
$report=@{schema=1;finishedAtUTC=[DateTime]::UtcNow.ToString('o');checks=$results;passed=(@($results|Where-Object{!$_.passed}).Count -eq 0);output=$output}
$report|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $Build 'semantics-report.json') -Encoding UTF8
if(!$report.passed){exit 1}
