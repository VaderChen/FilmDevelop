param([string]$Build=$PSScriptRoot)
. (Join-Path $PSScriptRoot 'windows-smoke-common.ps1') -Build $Build
$catalog=Get-Content -Raw -Encoding UTF8 (Join-Path $Build 'style-catalog.json')|ConvertFrom-Json
$originalHash=''
Check '37 個共用配方能力完整' {
 $reply=Invoke-Engine 'capabilities' @{}
 Require ($reply.kind -eq 'result') ($reply.error|ConvertTo-Json -Compress)
 Require ($reply.payload.supportedStyles.Count -eq $catalog.styles.Count) '引擎配方數量不符'
 foreach($style in $catalog.styles){Require ($reply.payload.supportedStyles -contains $style.id) ('遺漏配方：'+$style.id)}
 return @{count=$reply.payload.supportedStyles.Count;gpu=$reply.payload.gpu}
}
foreach($style in $catalog.styles){
 Check ('配方：'+$style.id) {
  $job=New-Job 'vulkan' 0 'png' 16
  $job.recipe.style=$style.id;$job.recipe.adjustment=$style.adjustment
  $reply=Invoke-Engine 'preview' $job
  Require ($reply.kind -eq 'result') ($reply.error|ConvertTo-Json -Compress)
  Require ($reply.payload.computeRoute -eq 'vulkan') '未使用 GPU'
  $hash=(Get-FileHash -LiteralPath $job.output.path).Hash
  if($style.id -eq 'original'){$script:originalHash=$hash}else{Require ($hash -ne $script:originalHash) '配方仍輸出原片'}
  return @{id=$style.id;timing=$reply.payload.timing;file=$job.output.path;hash=$hash}
 }
}
foreach($id in @('filmEktachrome100','filmHP5')) {
 Check ('底片強度 0 回到原片：'+$id) {
  $job=New-Job 'vulkan' 0 'png' 16;$style=$catalog.styles|Where-Object id -eq $id
  $job.recipe.style=$id;$job.recipe.adjustment=($style.adjustment|ConvertTo-Json -Depth 30|ConvertFrom-Json);$job.recipe.adjustment.intensity=0
  $reply=Invoke-Engine 'preview' $job
  Require ($reply.kind -eq 'result') ($reply.error|ConvertTo-Json -Compress)
  Require ((Get-FileHash -LiteralPath $job.output.path).Hash -eq $script:originalHash) '零強度沒有恢復原片'
 }
}
Check '底片無 GPU 時使用 CPU 完整回退' {
 $isolated=Join-Path $Build 'film-cpu-only';New-Item -ItemType Directory -Force -Path $isolated|Out-Null
 foreach($name in @('filmdevelop-engine.exe','neutral-recipe.json','style-catalog.json','film-data')) {Copy-Item -LiteralPath (Join-Path $Build $name) -Destination $isolated -Recurse -Force}
 Get-ChildItem -LiteralPath $Build -Filter *.dll | Where-Object Name -NotIn @('libPhotoCompute.dll','fault-compute.dll') | Copy-Item -Destination $isolated -Force
 $job=New-Job 'system' 0 'png' 16;$style=$catalog.styles|Where-Object id -eq 'filmEktachrome100';$job.recipe.style=$style.id;$job.recipe.adjustment=$style.adjustment
 $process=Start-Native 'film-cpu-only\filmdevelop-engine.exe'
 try {
  $reply=Request $process 'preview' $job
  Require ($reply.kind -eq 'result' -and $reply.payload.computeRoute -eq 'cpu') ($reply.error|ConvertTo-Json -Compress)
  Require ((Get-FileHash -LiteralPath $job.output.path).Hash -ne $script:originalHash) 'CPU 配方未套用'
  return $reply.payload.timing
 } finally {$process.StandardInput.Close();if(!$process.WaitForExit(5000)){$process.Kill()};$process.Dispose()}
}
Check '光學、乳劑 CPU／Vulkan 與透明度' {Run-Native 'photo_compute_optics_verify.exe' 'film-data film.comp.spv'}
Check '所有 Swift 配方與編輯金樣本：實際 Windows Vulkan' {Run-Native 'photo_compute_styles_verify.exe' 'film-data film.comp.spv style-cases\cases.json style-cases'}
$report=@{schema=1;finishedAtUTC=[DateTime]::UtcNow.ToString('o');checks=$results;passed=(@($results|Where-Object{!$_.passed}).Count -eq 0);output=$output}
$report|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $Build 'film-report.json') -Encoding UTF8
if(!$report.passed){exit 1}
