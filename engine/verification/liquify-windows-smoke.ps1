param([Parameter(Mandatory=$true)][string]$App,
      [Parameter(Mandatory=$true)][string]$Smoke,
      [Parameter(Mandatory=$true)][string]$NativeProbe,
      [Parameter(Mandatory=$true)][string]$Fixtures,
      [Parameter(Mandatory=$true)][string]$RepairModel,
      [Parameter(Mandatory=$true)][string]$Work)
# 只操作新建隔離目錄及其解壓產品副本；實際執行 WebView2 與正式 C++ 引擎。
$ErrorActionPreference='Stop'
$utf8=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=$utf8
if(Test-Path -LiteralPath $Work){throw '測試目錄已存在'}
[void](New-Item -ItemType Directory -Path $Work)
$checks=[Collections.Generic.List[object]]::new()
function Require($Value,$Message){if(!$Value){throw $Message}}
function Save($Name,$Value){[IO.File]::WriteAllText((Join-Path $Work $Name),($Value|ConvertTo-Json -Depth 24),$utf8)}
function Run($Exe,$Arguments,$Name){
 $p=[Diagnostics.Process]::new()
 $p.StartInfo=[Diagnostics.ProcessStartInfo]::new($Exe,$Arguments)
 $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true
 $p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
 [void]$p.Start();$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
 try {
  if(!$p.WaitForExit(240000)){$p.Kill();throw ('程序逾時：'+$Name)}
  [IO.File]::WriteAllText((Join-Path $Work ($Name+'.log')),($stdout.Result+$stderr.Result),$utf8)
  Require ($p.ExitCode -eq 0) ('程序失敗：'+$Name)
  return $stdout.Result
 } finally {$p.Dispose()}
}
try {
 Add-Type -AssemblyName System.Drawing
 Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class LiquifyPixels {
 public static double Compare(string actual, string expected) {
  byte[] a=File.ReadAllBytes(actual), b=File.ReadAllBytes(expected);
  if(a.Length!=b.Length || a.Length%4!=0) throw new Exception("Float32 長度不符");
  double maximum=0;
  for(int i=0;i<a.Length;i+=4) {
   float x=BitConverter.ToSingle(a,i), y=BitConverter.ToSingle(b,i);
   if(float.IsNaN(x)||float.IsInfinity(x)) throw new Exception("出現非有限值");
   maximum=Math.Max(maximum,Math.Abs((double)x-y));
  }
  return maximum;
 }
}
'@
 foreach($mesh in @('identity','mesh')){
  foreach($size in @(@(131,103),@(261,205),@(67,53))){
   $width=$size[0];$height=$size[1];$name=$mesh+'-'+$width
   $target=Join-Path $Work ($name+'.f32')
   $arguments='"'+(Join-Path $Fixtures ($mesh+'.json'))+'" '+$width+' '+$height+' "'+$target+'"'
   [void](Run $NativeProbe $arguments $name)
   $error=[LiquifyPixels]::Compare($target,(Join-Path $Fixtures ($name+'-cpp.f32')))
   Require ($error -le 0.000002) ('Windows Float32 取樣差異過大：'+$name)
   $checks.Add(@{name=$name;kind='native-pixels';passed=$true;maximumError=$error;tolerance=0.000002})
  }
 }
 foreach($file in Get-ChildItem -LiteralPath $Fixtures -Filter 'invalid-*.json'){
  $target=Join-Path $Work ($file.BaseName+'.f32')
  $p=Start-Process -FilePath $NativeProbe -ArgumentList @(('"'+$file.FullName+'"'),'131','103',('"'+$target+'"')) -Wait -PassThru -NoNewWindow -RedirectStandardError (Join-Path $Work ($file.BaseName+'.log'))
  try {Require ($p.ExitCode -eq 1 -and !(Test-Path $target)) ('未拒絕非法網格：'+$file.Name)} finally {$p.Dispose()}
  $checks.Add(@{name=$file.BaseName;kind='invalid-mesh';passed=$true})
 }
 Save 'native-report.json' @{passed=$true;checks=@($checks.ToArray())}
 $data=Join-Path $Work 'data'
 $model=Join-Path $data 'repair-models/LaMa-ONNX-c3c0c9e468934d62e79c329e35d82dd09ff8c444'
 [void](New-Item -ItemType Directory -Path $model -Force)
 Copy-Item -LiteralPath $RepairModel -Destination (Join-Path $model 'lama_fp32.onnx')
 Require ((Get-FileHash (Join-Path $model 'lama_fp32.onnx')).Hash -eq '1faef5301d78db7dda502fe59966957ec4b79dd64e16f03ed96913c7a4eb68d6') '修復模型摘要不符'
 Get-ChildItem Env:FILMDEVELOP_SMOKE_*|Remove-Item
 $env:FILMDEVELOP_ENGINE=Join-Path $App 'engine/filmdevelop-engine.exe'
 $env:FILMDEVELOP_DATA_DIR=$data
 $env:FILMDEVELOP_SMOKE_INPUT=Join-Path $Fixtures 'grid.bmp'
 $runs=[Collections.Generic.List[object]]::new()
 foreach($mode in @('edit','restore')){
  $env:FILMDEVELOP_SMOKE_LIQUIFY=$mode
  $env:FILMDEVELOP_SMOKE_REPORT=Join-Path $Work ($mode+'-report.json')
  $env:FILMDEVELOP_SMOKE_OUTPUT=Join-Path $Work ($mode+'.png')
  [void](Run $Smoke '' ('ui-'+$mode))
  $report=Get-Content -Raw -Encoding UTF8 $env:FILMDEVELOP_SMOKE_REPORT|ConvertFrom-Json
  Require $report.passed ($report|ConvertTo-Json -Compress -Depth 12)
  $image=[Drawing.Image]::FromFile($env:FILMDEVELOP_SMOKE_OUTPUT)
  try {Require ($image.Width -eq 1536 -and $image.Height -eq 1024) '液化正式匯出尺寸不符'} finally {$image.Dispose()}
  $runs.Add($report)
 }
 Require ($runs[0].liquifyRevision -eq $runs[1].liquifyRevision) '重開網格不同'
 Require ((Get-FileHash (Join-Path $Work 'edit.png')).Hash -eq (Get-FileHash (Join-Path $Work 'restore.png')).Hash) '重開後匯出不同'
 Save 'ui-report.json' @{passed=$true;runs=@($runs.ToArray());restartPNGIdentical=$true;width=1536;height=1024}
 Get-ChildItem Env:FILMDEVELOP_SMOKE_*|Remove-Item
 $mesh=Get-Content -Raw -Encoding UTF8 (Join-Path $Fixtures 'mesh.json')|ConvertFrom-Json
 $renders=[Collections.Generic.List[object]]::new()
 $library=Join-Path $App 'engine/libPhotoCompute.dll';$held=$library+'.liquify-smoke-held'
 Require (!(Test-Path $held)) '既有暫存 DLL 不可覆蓋'
 try {
  foreach($route in @('vulkan','cpu')){
   if($route -eq 'cpu'){Move-Item -LiteralPath $library -Destination $held}
   foreach($format in @('png','jpeg')){
    foreach($case in @('identity','liquify')){
     $name=$route+'-'+$format+'-'+$case;$target=Join-Path $Work ($name+'.'+$format)
     $recipe=@{version=1;style='original';adjustment=@{};repairPatches=@();detectSubject=$false}
     if($case -eq 'liquify'){$recipe.liquify=$mesh}
     $backend=if($route -eq 'cpu'){'system'}else{'vulkan'}
     $job=@{input=@{path=$env:FILMDEVELOP_SMOKE_INPUT;rawDecoder='system';lensCorrection=$false};output=@{path=$target;format=$format;bitDepth=16;colorSpace='sRGB';quality=.95;maxPixel=0;webPLossless=$false;tiffCompression=1};recipe=$recipe;computeBackend=$backend;preview=$false;previewMaxPixel=1024}
     # 清除 Smoke 環境變數後仍使用同一張唯讀原尺寸格線。
     $job.input.path=Join-Path $Fixtures 'grid.bmp'
     Save ($name+'.json') $job
     $reply=Run (Join-Path $App 'filmdevelop-cli.exe') ('-engine "'+$env:FILMDEVELOP_ENGINE+'" -method render -request "'+(Join-Path $Work ($name+'.json'))+'"') $name|ConvertFrom-Json
     Require ($reply.computeRoute -eq $route -and $reply.bytes -eq (Get-Item $target).Length -and $reply.bytes -gt 0) ('匯出後端或容量錯誤：'+$name)
     $image=[Drawing.Image]::FromFile($target)
     try {Require ($image.Width -eq 1536 -and $image.Height -eq 1024) ('匯出尺寸錯誤：'+$name)} finally {$image.Dispose()}
     $renders.Add(@{name=$name;passed=$true;route=$route;bytes=$reply.bytes;sha256=(Get-FileHash $target).Hash})
    }
    Require (($renders|Where-Object name -eq ($route+'-'+$format+'-identity')).sha256 -ne ($renders|Where-Object name -eq ($route+'-'+$format+'-liquify')).sha256) '液化匯出未改變圖像'
   }
  }
 } finally {if(Test-Path $held){Move-Item -LiteralPath $held -Destination $library}}
 Save 'render-report.json' @{passed=$true;cases=@($renders.ToArray());cpuFallback='僅隔離產品副本暫移 GPU DLL，完成後還原'}
 Save 'report.json' @{passed=$true;nativeChecks=$checks.Count;uiChecks=($runs|ForEach-Object {$_.completed.Count}|Measure-Object -Sum).Sum;exports=$renders.Count;os=[Environment]::OSVersion.VersionString}
} catch {
 Save 'report.json' @{passed=$false;error=$_.Exception.Message;stack=$_.ScriptStackTrace}
 exit 1
}
