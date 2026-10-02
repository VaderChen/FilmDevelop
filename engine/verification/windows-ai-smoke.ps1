param([string]$Build=$PSScriptRoot)
. (Join-Path $PSScriptRoot 'windows-smoke-common.ps1') -Build $Build
$job=New-Job
$sourceHash=(Get-FileHash $job.input.path).Hash
Check 'AI 照片分析與原片一致' {
 $reply=Invoke-Engine 'analysis' @{input=$job.input;recipe=$job.recipe}
 Require ($reply.kind -eq 'result') ($reply.error|ConvertTo-Json -Compress)
 Require ($reply.payload.analysis -match 'median=.*mean=.*p95=') '缺少亮度證據'
 Require ([Convert]::FromBase64String($reply.payload.imageData).Length -gt 1000) '分析照片無效'
 $script:analysis=$reply.payload
 return @{analysis=$reply.payload.analysis;imageBytes=[Convert]::FromBase64String($reply.payload.imageData).Length}
}
Check 'LaMa 模型準備與 GPU 自動選擇' {
 $reply=Invoke-Engine 'prepareRepair' @{path=(Join-Path $Build 'models')}
 Require ($reply.kind -eq 'result') ($reply.error|ConvertTo-Json -Compress)
 Require $reply.payload.ready '模型未就緒'
 Require ($reply.payload.inputs.Count -eq 2 -and $reply.payload.outputs.Count -eq 1) '修復張量契約不符'
 return $reply.payload
}
Check 'LaMa 實際修復、保存與重開套用' {
 $reply=Invoke-Engine 'repair' @{input=$job.input;recipe=$job.recipe;modelDirectory=(Join-Path $Build 'models');strokes=@(@{radius=.025;points=@(@{x=.48;y=.5},@{x=.52;y=.5})})}
 Require ($reply.kind -eq 'result') ($reply.error|ConvertTo-Json -Compress)
 $patch=$reply.payload
 Require ($patch.width -gt 0 -and $patch.height -gt 0 -and $patch.linearGain -ge 1) '修復貼片座標或增益不符'
 Require ([Convert]::FromBase64String($patch.imageData).Length -gt 1000 -and [Convert]::FromBase64String($patch.maskData).Length -gt 100) '修復貼片內容無效'
 $job.output.format='png';$job.output.bitDepth=16
 $before=Invoke-Engine 'render' $job;Require ($before.kind -eq 'result') ($before.error|ConvertTo-Json -Compress)
 $beforeHash=(Get-FileHash $job.output.path).Hash
 $job.recipe.repairPatches=@($patch);$job.output.path=Join-Path $output 'repaired.png'
 $after=Invoke-Engine 'render' $job;Require ($after.kind -eq 'result') ($after.error|ConvertTo-Json -Compress)
 $afterHash=(Get-FileHash $job.output.path).Hash
 Require ($beforeHash -ne $afterHash) '修復未改變影像'
 $job.recipe.repairPatches|ConvertTo-Json -Depth 20|Set-Content (Join-Path $output 'patch.json') -Encoding UTF8
 $job.recipe.repairPatches=@(Get-Content -Raw (Join-Path $output 'patch.json')|ConvertFrom-Json);$job.output.path=Join-Path $output 'reopened.png'
 $reopened=Invoke-Engine 'render' $job;Require ($reopened.kind -eq 'result') ($reopened.error|ConvertTo-Json -Compress)
 Require ((Get-FileHash $job.output.path).Hash -eq $afterHash) '修復重開結果不同'
 return @{patch=@{x=$patch.x;y=$patch.y;width=$patch.width;height=$patch.height;linearGain=$patch.linearGain};before=$beforeHash;after=$afterHash}
}
Check '修復空白筆刷可回報錯誤' {
 $reply=Invoke-Engine 'repair' @{input=$job.input;recipe=$job.recipe;modelDirectory=(Join-Path $Build 'models');strokes=@()}
 Require ($reply.kind -eq 'error' -and $reply.error.code -eq 'invalidMask') ($reply|ConvertTo-Json -Compress)
}
function Infer-Request {
 return @{format='gguf';modelPath=(Join-Path $Build 'models\SmolVLM-500M-Instruct-Q8_0.gguf');projectorPath=(Join-Path $Build 'models\mmproj-SmolVLM-500M-Instruct-Q8_0.gguf');imageData=$analysis.imageData;systemPrompt='Describe the photo. Return JSON only.';userPrompt="<image>`nDescribe the image brightness as dark, normal or bright.";grammar='root ::= "{" ws "\"brightness\"" ws ":" ws ("\"dark\"" | "\"normal\"" | "\"bright\"") ws "}" ws'+"`n"+'ws ::= [ \t\n\r]*';maxTokens=96;contextLimit=4096}
}
Check 'GGUF 視覺模型 GPU 推論與 JSON 契約' {
 $reply=Invoke-Engine 'infer' (Infer-Request)
 Require ($reply.kind -eq 'result') ($reply.error|ConvertTo-Json -Compress)
 $answer=$reply.payload.text|ConvertFrom-Json
 Require (@('dark','normal','bright') -contains $answer.brightness) '模型沒有遵守 JSON 契約'
 Require ($reply.payload.computeRoute -eq 'vulkan') 'GPU 未被使用'
 return $reply.payload
}
Check 'GGUF 無 GPU 提供者時完整回退 CPU' {
 $module=Join-Path $Build 'ggml-vulkan.dll';$disabled=$module+'.disabled'
 Move-Item -LiteralPath $module -Destination $disabled
 try {
  $reply=Invoke-Engine 'infer' (Infer-Request)
  Require ($reply.kind -eq 'result') ($reply.error|ConvertTo-Json -Compress)
  Require ($reply.payload.computeRoute -eq 'cpu') '未完整回退 CPU'
  $answer=$reply.payload.text|ConvertFrom-Json;Require (@('dark','normal','bright') -contains $answer.brightness) 'CPU 模型回覆不完整'
  return $reply.payload
 } finally {Move-Item -LiteralPath $disabled -Destination $module}
}
Check 'AI 操作沒有覆寫照片來源' {Require ((Get-FileHash $job.input.path).Hash -eq $sourceHash) '原片被修改'}
$report=@{schema=1;finishedAtUTC=[DateTime]::UtcNow.ToString('o');checks=$results;passed=(@($results|Where-Object{!$_.passed}).Count -eq 0);output=$output}
$report|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $Build 'ai-report.json') -Encoding UTF8
if(!$report.passed){exit 1}
