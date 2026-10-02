param([string]$Build = $PSScriptRoot, [string]$Only = '', [string]$ReportName = 'runtime-report.json')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$Build = [IO.Path]::GetFullPath($Build)
$results = [Collections.Generic.List[object]]::new()
$output = Join-Path $Build ('results-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $output | Out-Null

function Check([string]$Name, [scriptblock]$Body) {
    if($Only -and $Name -notmatch $Only){return}
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try { $detail = & $Body; $script:results.Add([pscustomobject]@{name=$Name;passed=$true;milliseconds=$clock.ElapsedMilliseconds;detail=$detail}) }
    catch { $script:results.Add([pscustomobject]@{name=$Name;passed=$false;milliseconds=$clock.ElapsedMilliseconds;error=$_.Exception.Message}) }
    $script:results | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $output 'checks.json') -Encoding UTF8
}
function Start-Native([string]$Name, [string]$Arguments='') {
    $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $Build $Name), $Arguments)
    $info.WorkingDirectory=$Build; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false); $info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$info; [void]$process.Start(); $process | Add-Member -NotePropertyName ErrorRead -NotePropertyValue ($process.StandardError.ReadToEndAsync()); return $process
}
function Run-Native([string]$Name, [string]$Arguments='') {
    $process=Start-Native $Name $Arguments
    try {
        $process.StandardInput.Close(); $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.ErrorRead
        if(!$process.WaitForExit(120000)){ $process.Kill();throw '原生測試逾時' }
        $text=$stdout.Result+$stderr.Result
        if($process.ExitCode -ne 0){throw ($Name+'：'+$process.ExitCode+' '+$text)}
        return $text
    } finally {$process.Dispose()}
}
function Request($Process, [string]$Method, $Payload) {
    $id=[guid]::NewGuid().ToString('N')
    $packet=@{version=1;id=$id;method=$Method;payload=$Payload}|ConvertTo-Json -Depth 50 -Compress
    # StreamWriter 的預設 UTF-8 保留中文路徑；不用 PowerShell 的舊版 ASCII 管線。
    $Process.StandardInput.WriteLine($packet);$Process.StandardInput.Flush()
    while($true) {
        $read=$Process.StandardOutput.ReadLineAsync()
        if(!$read.Wait(120000)){$Process.Kill();throw '原生工作逾時'}
        if($null -eq $read.Result){[void]$Process.WaitForExit(1000);throw ('引擎沒有回覆，結束代碼 '+$Process.ExitCode+'：'+$Process.ErrorRead.Result)}
        $reply=$read.Result|ConvertFrom-Json
        if($reply.id -ne $id){throw '引擎回覆識別不符'}
        if($reply.kind -eq 'progress'){continue}
        return $reply
    }
}
function Invoke-Engine([string]$Method, $Payload) {
    $process=Start-Native 'filmdevelop-engine.exe'
    try { $reply=Request $process $Method $Payload; $process.StandardInput.Close(); if(!$process.WaitForExit(5000)){$process.Kill();throw '引擎未收回'};return $reply }
    finally {$process.Dispose()}
}
function Require($Condition,[string]$Message){if(!$Condition){throw $Message}}
function New-Job([string]$Backend='system',[double]$Exposure=0,[string]$Format='jpeg',[int]$Bits=8) {
    $adjustment=Get-Content -Raw -LiteralPath (Join-Path $Build 'neutral-recipe.json') -Encoding UTF8|ConvertFrom-Json
    $adjustment.filmEffects.print_exposure=$Exposure
    return @{input=@{path=(Join-Path $Build '中文 橫向.jpg');rawDecoder='system';lensCorrection=$true};
        output=@{path=(Join-Path $output ([guid]::NewGuid().ToString('N')+'.'+$Format));format=$Format;bitDepth=$Bits;colorSpace='sRGB';quality=.88;maxPixel=320;webPLossless=$false;tiffCompression=1};
        recipe=@{version=1;style='original';adjustment=$adjustment;repairPatches=@();detectSubject=$false};
        computeBackend=$Backend;preview=$true;previewMaxPixel=320;policy=@{highlightProtection=$true;modernExposure=$false;hdr=$true;fullResolution=$false}}
}

# 從獨立的 GDI+ 讀取測試照片及 EXIF 方向；不可假設中文檔名一定是橫幅。
function Expected-ImageSize([string]$Path,[int]$MaxPixel) {
    Add-Type -AssemblyName System.Drawing
    $image=[Drawing.Image]::FromFile($Path)
    try {
        $width=$image.Width; $height=$image.Height
        if($image.PropertyIdList -contains 274) {
            $orientation=[BitConverter]::ToUInt16($image.GetPropertyItem(274).Value,0)
            if($orientation -ge 5 -and $orientation -le 8){$temporary=$width;$width=$height;$height=$temporary}
        }
        return Limit-ImageSize $width $height $MaxPixel
    } finally {$image.Dispose()}
}

function Limit-ImageSize([int]$Width,[int]$Height,[int]$MaxPixel) {
    if($MaxPixel -gt 0 -and [Math]::Max($Width,$Height) -gt $MaxPixel) {
        $scale=$MaxPixel/[double][Math]::Max($Width,$Height)
        $Width=[Math]::Max(1,[Math]::Round($Width*$scale,[MidpointRounding]::AwayFromZero))
        $Height=[Math]::Max(1,[Math]::Round($Height*$scale,[MidpointRounding]::AwayFromZero))
    }
    return @($Width,$Height)
}
