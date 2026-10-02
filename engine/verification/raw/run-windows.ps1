param([string]$Probe = 'probe-windows-before.exe', [string]$Output = 'windows-before', [string]$Manifest = 'manifest.json', [string]$Samples = 'samples', [switch]$Download, [switch]$Half)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-Location $PSScriptRoot
if (-not (Test-Path RAWMapping)) {
    Copy-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'Programs\FilmDevelop\engine\RAWMapping') -Destination RAWMapping -Recurse
}
$manifestData = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Force $Samples,$Output | Out-Null
if ($Download) {
    $config = @('--parallel', '--parallel-max 3', '--fail', '--location', '--retry 3', '--max-time 300')
    foreach ($row in $manifestData.samples) {
        if (-not $row.url) { continue }
        $source = Join-Path $Samples $row.file
        if ((Test-Path $source) -and (Get-FileHash $source).Hash -eq $row.sha256) { continue }
        if ($row.license -ne 'CC0-1.0') { throw 'Unexpected sample license' }
        $url = [Uri]::new($row.url).AbsoluteUri.Replace(' ', '%20')
        $config += 'url = "' + $url + '"'
        $config += 'output = "' + $source.Replace('\','/') + '.download"'
    }
    $config | Set-Content -LiteralPath 'downloads.txt' -Encoding ASCII
    $ErrorActionPreference = 'Continue'
    & curl.exe --config downloads.txt 2> downloads.log
    $downloadExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($downloadExit -ne 0) { throw ('curl failed: '+$downloadExit) }
    foreach ($row in $manifestData.samples) {
        $part = Join-Path $Samples ($row.file+'.download')
        if (Test-Path $part) {
            if ((Get-FileHash $part).Hash -ne $row.sha256) { throw ('SHA-256 mismatch: '+$row.id) }
            Move-Item -LiteralPath $part -Destination (Join-Path $Samples $row.file) -Force
        }
    }
}
$report = @()
foreach ($row in $manifestData.samples) {
    $source = Join-Path $PSScriptRoot ($Samples+'\'+$row.file)
    $destination = Join-Path $PSScriptRoot ($Output+'\'+$row.id+'.json')
    try {
        if ((Get-FileHash -LiteralPath $source).Hash -ne $row.sha256) { throw 'Source hash mismatch' }
        # 直接持有 .NET Process，避免 Windows PowerShell 的 Start-Process
        # 在短行程結束後回傳 null ExitCode，將正常解碼誤判為失敗。
        $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSScriptRoot $Probe))
        $info.Arguments = '"'+$source+'" "'+$destination+'" "'+$PSScriptRoot+'\RAWMapping" '+[int][bool]$Half
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardError=$true
        $p=[Diagnostics.Process]::new();$p.StartInfo=$info
        try {
            [void]$p.Start();$stderr=$p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit(180000)) { $p.Kill(); throw 'Decode exceeded 180 seconds' }
            $stderr.Result | Set-Content ($destination+'.stderr') -Encoding UTF8
            if ($p.ExitCode -ne 0 -or -not (Test-Path $destination)) { throw ('Native exit: '+$p.ExitCode) }
        } finally { $p.Dispose() }
        $result = Get-Content $destination -Raw -Encoding UTF8 | ConvertFrom-Json
        $result.PSObject.Properties.Remove('linearSamples')
        $result.PSObject.Properties.Remove('displaySamples')
        $result | Add-Member id $row.id
        $result | Add-Member sourceUnchanged ((Get-FileHash -LiteralPath $source).Hash -eq $row.sha256)
    } catch { $result = @{id=$row.id; status=-999; error=$_.Exception.Message} }
    $report += $result
    ConvertTo-Json -InputObject $report -Depth 10 | Set-Content -LiteralPath ($Output+'\report.json') -Encoding UTF8
    Write-Output ($row.id+' '+$result.status+' '+$result.error)
}
Write-Output 'RAW_CORPUS_DONE'
