param([switch]$Silent, [switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

try {
    if (![Environment]::Is64BitProcess) { throw '請使用 Windows x64 PowerShell 檢查執行環境。' }
    $config = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'prerequisites.json') -Raw -Encoding UTF8 | ConvertFrom-Json).visualCppX64
    $minimum = [version]$config.minimumVersion
    function Test-Runtime {
        foreach ($name in $config.dlls) {
            $path = Join-Path ([Environment]::SystemDirectory) $name
            if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
            $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            $version = [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
            if ($version -lt $minimum) { return $false }
        }
        return $true
    }
    if (Test-Runtime) { Write-Output 'Microsoft Visual C++ x64 執行環境已就緒。'; exit 0 }
    if ($CheckOnly -or $Silent) {
        Write-Error '缺少 Microsoft Visual C++ x64 執行環境。請先安裝 Microsoft 官方套件，或以互動模式執行 FilmDevelop 安裝程式。' -ErrorAction Continue
        exit 20
    }
    # 只在需要時從 Microsoft 下載官方安裝器；不自行複製系統 DLL。
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('FilmDevelop-runtime-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory | Out-Null
    try {
        $installer = Join-Path $directory 'VC_redist.x64.exe'
        Write-Output '正在下載 Microsoft Visual C++ x64 執行環境…'
        Invoke-WebRequest -UseBasicParsing -Uri $config.url -OutFile $installer -TimeoutSec 180
        if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne $config.sha256) { throw 'Microsoft 安裝器 SHA-256 不符，已停止安裝。' }
        $signature = Get-AuthenticodeSignature -LiteralPath $installer
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') { throw 'Microsoft 安裝器簽章驗證失敗。' }
        Write-Output '正在安裝 Microsoft 執行環境；Windows 可能會要求系統管理員確認。'
        $process = Start-Process -FilePath $installer -ArgumentList '/install /passive /norestart' -Verb RunAs -Wait -PassThru
        if ($process.ExitCode -eq 3010) { Write-Output 'Microsoft 執行環境需要重新啟動 Windows。'; exit 3010 }
        if ($process.ExitCode -ne 0 -or !(Test-Runtime)) { throw ('Microsoft 執行環境安裝未完成，結束代碼：' + $process.ExitCode) }
    } finally {
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    }
    Write-Output 'Microsoft Visual C++ x64 執行環境已就緒。'
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 21
}
