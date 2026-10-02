param([Parameter(Mandatory=$true)][string]$Archive,
      [Parameter(Mandatory=$true)][string]$Work,
      [Parameter(Mandatory=$true)][string]$UpdaterTests,
      [Parameter(Mandatory=$true)][string]$UISmoke)
# 僅在全新測試目錄解壓，使用隔離資料；不安裝 Runtime，也不修改正式使用者設定。
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$results=[Collections.Generic.List[object]]::new()
if(Test-Path -LiteralPath $Work){throw '測試目錄已存在，請指定全新目錄'}
New-Item -ItemType Directory -Path $Work|Out-Null
$report=Join-Path $Work 'report.json'
function Require($Value,[string]$Message){if(!$Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Body){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try {$detail=& $Body;$results.Add(@{name=$Name;passed=$true;detail=$detail;milliseconds=$watch.ElapsedMilliseconds})}
    catch {$results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message;milliseconds=$watch.ElapsedMilliseconds})}
    @{passed=(@($results|Where-Object {!$_.passed}).Count -eq 0);checks=@($results.ToArray());os=[Environment]::OSVersion.VersionString}|ConvertTo-Json -Depth 12|Set-Content -Encoding UTF8 -LiteralPath $report
}
function Run([string]$Exe,[string]$Arguments,[string]$Log){
    $info=[Diagnostics.ProcessStartInfo]::new($Exe,$Arguments)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;[void]$p.Start()
    $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
    try {
        if(!$p.WaitForExit(240000)){$p.Kill();throw '測試程序逾時'}
        ($stdout.Result+$stderr.Result)|Set-Content -Encoding UTF8 -LiteralPath (Join-Path $Work $Log)
        Require ($p.ExitCode -eq 0) ('測試結束代碼 '+$p.ExitCode+'，詳見 '+$Log)
    } finally {$p.Dispose()}
}
$app=Join-Path $Work 'FilmDevelop'
Check 'ZIP 完整解壓與產品識別' {
    Expand-Archive -LiteralPath $Archive -DestinationPath $Work
    $script:info=Get-Content -Raw -Encoding UTF8 (Join-Path $app 'build-info.json')|ConvertFrom-Json
    Require ($info.distribution -eq 'portable' -and $info.architecture -eq 'x64') '不是免安裝 x64 套件'
    Require (!(Test-Path (Join-Path $app 'Uninstall.exe')) -and !(Test-Path (Join-Path $app '.filmdevelop-installed.ini'))) 'ZIP 混入安裝器檔案'
    return @{archiveSHA256=(Get-FileHash $Archive).Hash;version=$info.version;build=$info.build}
}
Check '正式更新工具驗證 ZIP 清單與 x64' {
    Run (Join-Path $app 'filmdevelop-update.exe') ('--verify "'+$Archive+'" '+$info.version+' '+$info.build) 'verify.log'
    return @{fileCount=(Get-Content -Raw -Encoding UTF8 (Join-Path $app 'files.json')|ConvertFrom-Json).files.Count}
}
Check '原廠 Runtime 簽章、摘要與 app-local 載入' {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PortableRuntime {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr LoadLibraryEx(string path,IntPtr file,uint flags);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] public static extern uint GetModuleFileName(IntPtr module,StringBuilder name,int size);
 [DllImport("kernel32.dll")] public static extern bool FreeLibrary(IntPtr module);
}
'@
    $provenance=Get-Content -Raw -Encoding UTF8 (Join-Path $app 'Licenses\Windows\VisualCpp\provenance.json')|ConvertFrom-Json
    $loaded=[Collections.Generic.List[object]]::new()
    foreach($entry in $provenance.files){
        $path=Join-Path $app ('engine\'+$entry.path)
        Require ((Get-FileHash $path).Hash -eq $entry.sha256) ('Runtime 摘要不符：'+$entry.path)
        $signature=Get-AuthenticodeSignature -LiteralPath $path
        Require ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'O=Microsoft Corporation') ('Runtime 簽章不符：'+$entry.path+' '+$signature.Status)
        $handle=[PortableRuntime]::LoadLibraryEx($path,[IntPtr]::Zero,0x900)
        Require ($handle -ne [IntPtr]::Zero) ('Runtime 無法載入：'+$entry.path+' '+[Runtime.InteropServices.Marshal]::GetLastWin32Error())
        try {
            $buffer=[Text.StringBuilder]::new(32768);[void][PortableRuntime]::GetModuleFileName($handle,$buffer,$buffer.Capacity)
            Require ($buffer.ToString() -ieq $path) ('Runtime 載入了其他位置：'+$entry.path)
            $loaded.Add(@{name=$entry.path;version=$entry.version;signature='Valid';local=$true})
        } finally {[void][PortableRuntime]::FreeLibrary($handle)}
    }
    return @($loaded.ToArray())
}
Check 'Go Windows 更新、檔案保留與啟動失敗還原' {
    $env:FILMDEVELOP_TEST_UPDATER=Join-Path $app 'filmdevelop-update.exe'
    try {Run $UpdaterTests '-test.v -test.timeout=180s' 'updater-tests.log'}
    finally {Remove-Item Env:FILMDEVELOP_TEST_UPDATER}
    return @{processHandshake=$true;rollback=$true;userFilesPreserved=$true}
}
Check '正式免安裝 GUI、影像引擎與 Beta 版本' {
    $env:FILMDEVELOP_DATA_DIR=Join-Path $Work 'formal-data'
    $p=Start-Process -FilePath (Join-Path $app 'FilmDevelop.exe') -PassThru
    try {
        Start-Sleep -Seconds 8;$p.Refresh()
        Require (!$p.HasExited -and $p.Responding -and $p.MainWindowHandle -ne 0) '正式 GUI 未正常啟動'
        Require ((Get-Item (Join-Path $app 'FilmDevelop.exe')).VersionInfo.ProductVersion.EndsWith(' Beta')) '版本缺少 Beta'
        return @{title=$p.MainWindowTitle;version=(Get-Item (Join-Path $app 'FilmDevelop.exe')).VersionInfo.ProductVersion}
    } finally {
        if(!$p.HasExited){[void]$p.CloseMainWindow();if(!$p.WaitForExit(15000)){$p.Kill()}}
        $p.Dispose()
    }
}
Check 'Go／WebView2 預覽、配方與 GPU 切換' {
    Add-Type -AssemblyName System.Drawing
    $photo=Join-Path $Work '測試 照片.jpg'
    $bitmap=[Drawing.Bitmap]::new(160,120)
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::CornflowerBlue)
        $graphics.FillRectangle([Drawing.Brushes]::Orange,20,20,60,60)
        $bitmap.Save($photo,[Drawing.Imaging.ImageFormat]::Jpeg)
    } finally {$graphics.Dispose();$bitmap.Dispose()}
    $env:FILMDEVELOP_ENGINE=Join-Path $app 'engine\filmdevelop-engine.exe'
    $env:FILMDEVELOP_DATA_DIR=Join-Path $Work 'ui-data'
    $env:FILMDEVELOP_SMOKE_INPUT=$photo
    $env:FILMDEVELOP_SMOKE_WINDOWS='fresh'
    $env:FILMDEVELOP_SMOKE_REPORT=Join-Path $Work 'ui-report.json'
    Run $UISmoke '' 'ui.log'
    $ui=Get-Content -Raw -Encoding UTF8 $env:FILMDEVELOP_SMOKE_REPORT|ConvertFrom-Json
    Require $ui.passed ($ui|ConvertTo-Json -Compress)
    return $ui
}
if(@($results|Where-Object {!$_.passed}).Count){exit 1}
