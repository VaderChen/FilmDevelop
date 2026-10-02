param([string]$Engine = 'engine\filmdevelop-engine.exe', [string]$Manifest = 'manifest.json', [string]$Samples = 'samples', [string]$Output = 'windows-engine', [ValidateSet('system','software')][string[]]$Decoders = @('system','software'))
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$records = (Get-Content $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json).samples
$adjustment = Get-Content 'neutral-recipe.json' -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Force $Output | Out-Null
$report = @()
foreach ($row in $records) {
    $source = Join-Path $PSScriptRoot ($Samples+'\'+$row.file)
    foreach ($decoder in $Decoders) {
        $id = $row.id+'-'+$decoder
        $destination = Join-Path $PSScriptRoot ($Output+'\'+$id+'.png')
        if (Test-Path $destination) { throw ('Output exists: '+$id) }
        $job = @{input=@{path=$source;rawDecoder=$decoder;lensCorrection=$false};
            output=@{path=$destination;format='png';bitDepth=16;colorSpace='sRGB';quality=.95;maxPixel=512;webPLossless=$false;tiffCompression=1};
            recipe=@{version=1;style='original';adjustment=$adjustment;repairPatches=@();detectSubject=$false};
            computeBackend='system';preview=$true;previewMaxPixel=512;
            policy=@{highlightProtection=$true;modernExposure=$false;hdr=$true;fullResolution=$false}}
        $result = @{id=$row.id;requestedDecoder=$decoder}
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $process = [Diagnostics.Process]::new()
        try {
            $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSScriptRoot $Engine))
            $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WorkingDirectory=Split-Path $info.FileName
            $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
            $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
            $process.StartInfo=$info;[void]$process.Start()
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            $request=@{version=1;id=$id;method='render';payload=$job} | ConvertTo-Json -Depth 50 -Compress
            $process.StandardInput.WriteLine($request);$process.StandardInput.Close()
            if (-not $process.WaitForExit(180000)) { $process.Kill();throw 'Engine exceeded 180 seconds' }
            $result.exitCode=$process.ExitCode
            foreach ($line in $stdout.Result.Split("`n")) {
                if (-not $line.StartsWith('{')) { continue }
                $reply=$line | ConvertFrom-Json
                if ($reply.kind -ne 'progress') { $result.reply=$reply }
            }
            if (-not $result.reply) { throw ('No JSONL result: '+$stderr.Result) }
            if (Test-Path $destination) {
                $result.outputBytes=(Get-Item $destination).Length
                $result.outputSHA256=(Get-FileHash $destination).Hash.ToLowerInvariant()
            }
            $result.sourceUnchanged=(Get-FileHash $source).Hash -eq $row.sha256
        } catch { $result.error=$_.Exception.Message }
        finally { $process.Dispose() }
        $result.seconds=$clock.Elapsed.TotalSeconds
        $report += $result
        ConvertTo-Json -InputObject $report -Depth 30 | Set-Content ($Output+'\report.json') -Encoding UTF8
        Write-Output ($id+' '+$result.reply.kind+' '+$result.error)
    }
}
Write-Output 'RAW_ENGINE_DONE'
