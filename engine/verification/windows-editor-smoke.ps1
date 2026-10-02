param([string]$Build=$PSScriptRoot)
. (Join-Path $PSScriptRoot 'windows-smoke-common.ps1') -Build $Build
$sourceHash=(Get-FileHash (Join-Path $Build '中文 橫向.jpg')).Hash
Check '原生方法與匯出格式' {
 $reply=Invoke-Engine 'capabilities' @{}
 Require ($reply.kind -eq 'result') ($reply.error|ConvertTo-Json -Compress)
 Require ($reply.payload.methods -contains 'whiteBalance') '缺少白平衡取樣'
 foreach($space in @('sRGB','adobeRGB','displayP3')){Require ($reply.payload.colorSpaces -contains $space) ('缺少色彩空間：'+$space)}
 Require ($reply.payload.formats.id -contains 'webp') '缺少 WebP'
 return $reply.payload.gpu
}
$whiteBalance=Get-Content -Raw -Encoding UTF8 (Join-Path $Build 'white-balance.json')|ConvertFrom-Json
$i=0
foreach($sample in $whiteBalance) {
 $i++
 Check ('白平衡取樣與 Swift 相符：'+$i) {
  $reply=Invoke-Engine 'whiteBalance' $sample.input
  Require ($reply.kind -eq $sample.expected.kind) ($reply|ConvertTo-Json -Compress)
  if($reply.kind -eq 'result') {
   Require ([Math]::Abs($reply.payload.warmth-$sample.expected.payload.warmth) -le .2 -and [Math]::Abs($reply.payload.tint-$sample.expected.payload.tint) -le .2) ('取樣差異：'+($reply.payload|ConvertTo-Json -Compress))
   return $reply.payload
  }
  Require ($reply.error.code -eq $sample.expected.error.code) ('錯誤代碼不符：'+$reply.error.code)
 }
}
foreach($space in @('sRGB','adobeRGB','displayP3')) {
 foreach($type in @(@('jpeg',8,$false),@('webp',8,$false),@('webp',8,$true),@('png',8,$false),@('png',16,$false),@('tiff',8,$false),@('tiff',16,$false))) {
  $format=$type[0];$bits=$type[1];$lossless=$type[2]
  Check ('匯出與重新解析：'+$space+' '+$format+' '+$bits+' 無損='+$lossless) {
   $job=New-Job 'system' 0 $format $bits;$job.preview=$false;$job.output.colorSpace=$space;$job.output.webPLossless=$lossless
   $reply=Invoke-Engine 'render' $job
   Require ($reply.kind -eq 'result') ($reply.error|ConvertTo-Json -Compress)
   $expected=Expected-ImageSize $job.input.path $job.output.maxPixel
   Require ($reply.payload.width -eq $expected[0] -and $reply.payload.height -eq $expected[1]) '匯出尺寸不符'
   $meta=Invoke-Engine 'metadata' @{path=$job.output.path}
   Require ($meta.kind -eq 'result') ($meta.error|ConvertTo-Json -Compress)
   Require ($meta.payload.ColorProfiles -ge 1) '成品未嵌入色彩描述'
   Require ($meta.payload.BitsPerPixel -ge $bits*3) ('成品位元深度不符：'+$meta.payload.BitsPerPixel)
   $thumbnail=Invoke-Engine 'thumbnail' @{path=$job.output.path;maxPixel=256}
   $thumbSize=Limit-ImageSize $expected[0] $expected[1] 256
   Require ($thumbnail.kind -eq 'result' -and $thumbnail.payload.width -eq $thumbSize[0] -and $thumbnail.payload.height -eq $thumbSize[1]) ($thumbnail.error|ConvertTo-Json -Compress)
   return @{metadata=$meta.payload;bytes=$reply.payload.bytes;path=$job.output.path;route=$reply.payload.computeRoute}
  }
 }
}
Add-Type -AssemblyName System.Drawing
function Image-Size([string]$Data) {
 $bytes=[Convert]::FromBase64String($Data.Substring($Data.IndexOf(',')+1))
 $stream=[IO.MemoryStream]::new($bytes);$image=[Drawing.Image]::FromStream($stream)
 try{return @($image.Width,$image.Height)}finally{$image.Dispose();$stream.Dispose()}
}
Check '裁切與比較圖、完整編輯圖各自維持正確座標' {
 $job=New-Job 'vulkan' 0 'png' 16;$job.recipe.adjustment.cropAspectRatio='oneOne';$job.recipe.adjustment.cropScale=76;$job.recipe.adjustment.cropRotation=13.5
 $reply=Invoke-Engine 'preview' $job
 Require ($reply.kind -eq 'result') ($reply.error|ConvertTo-Json -Compress)
 $edited=Image-Size $reply.payload.cropImage;$source=Image-Size $reply.payload.sourceImage
 Require ([Math]::Abs($reply.payload.width-$reply.payload.height) -le 1) '主圖沒有裁切成正方形'
 $expected=Expected-ImageSize $job.input.path $job.previewMaxPixel
 Require ($edited[0] -eq $expected[0] -and $edited[1] -eq $expected[1]) '裁切編輯圖未保留完整原片'
 Require ([Math]::Abs($source[0]-$source[1]) -le 1) '原片比較圖沒有套用相同裁切'
 return @{main=@($reply.payload.width,$reply.payload.height);editor=$edited;source=$source}
}
Check '保存修復貼片重開套用、來源不變、工作階段快取更新' {
 $cases=Get-Content -Raw -Encoding UTF8 (Join-Path $Build 'style-cases\cases.json')|ConvertFrom-Json
 $case=$cases.styles|Where-Object case -eq 'original-repair-rotated'
 $process=Start-Native 'filmdevelop-engine.exe' '--preview-session'
 try {
  $job=New-Job 'vulkan' 0 'png' 16;$job.recipe.adjustment=$case.adjustment;$job.recipe.repairPatches=@()
  $original=Request $process 'preview' $job;Require ($original.kind -eq 'result') ($original.error|ConvertTo-Json -Compress)
  $hash=(Get-FileHash $job.output.path).Hash
  $job.output.path=Join-Path $output 'repaired.png';$job.recipe.repairPatches=$case.repairPatches
  $repaired=Request $process 'preview' $job;Require ($repaired.kind -eq 'result') ($repaired.error|ConvertTo-Json -Compress)
  Require ((Get-FileHash $job.output.path).Hash -ne $hash) '修復貼片未套用'
  Require $repaired.payload.timing.sourceCacheHit '來源快取失效'
  $job.output.path=Join-Path $output 'reopened.png'
  $reopened=Invoke-Engine 'preview' $job;Require ($reopened.kind -eq 'result') ($reopened.error|ConvertTo-Json -Compress)
  Require ((Get-FileHash $job.output.path).Hash -eq (Get-FileHash (Join-Path $output 'repaired.png')).Hash) '重開後修復結果不同'
  Require ((Get-FileHash (Join-Path $Build '中文 橫向.jpg')).Hash -eq $sourceHash) '來源照片被修改'
  return $repaired.payload.timing
 } finally {$process.StandardInput.Close();if(!$process.WaitForExit(5000)){$process.Kill()};$process.Dispose()}
}
$report=@{schema=1;finishedAtUTC=[DateTime]::UtcNow.ToString('o');checks=$results;passed=(@($results|Where-Object{!$_.passed}).Count -eq 0);output=$output}
$report|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $Build 'editor-report.json') -Encoding UTF8
if(!$report.passed){exit 1}
