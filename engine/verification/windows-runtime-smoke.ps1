param([string]$Build = $PSScriptRoot, [string]$Only = '', [string]$ReportName = 'runtime-report.json')
# 其他檢查會使用能力探測結果；篩選執行時也必須先取得這項共用前置資料。
if($Only){$Only='(?:'+$Only+')|^系統解析器與 GPU 實際探測$'}
. (Join-Path $PSScriptRoot 'windows-smoke-common.ps1') -Build $Build -Only $Only -ReportName $ReportName

Check 'Windows 與使用者權限' {
    @{os=[Environment]::OSVersion.VersionString;architecture=$env:PROCESSOR_ARCHITECTURE;
      elevated=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
}
Check 'JSONL 契約與中文路徑' {Run-Native 'filmdevelop-contract-smoke.exe' '--self-test'}
Check 'Go 工作程序生命週期' {Run-Native 'engine-tests.exe' '-test.v -test.timeout=90s' (Go-TestDirectory 'engine')}
if(Test-Path (Join-Path $Build 'application-tests.exe')) {
    Check 'Go 共用應用層 Windows Smoke' {Run-Native 'application-tests.exe' '-test.v -test.timeout=90s' (Go-TestDirectory 'application')}
}
Check 'C++ 像素不變量' {Run-Native 'photo_core_verify.exe'}
Check 'C++ 顯影與取樣' {Run-Native 'photo_core_film_verify.exe'}
Check 'C++ 有界工作池、巢狀呼叫與例外復原' {Run-Native 'photo_core_rows_verify.exe'}
$capabilities=$null
Check '系統解析器與 GPU 實際探測' {
    $reply=Invoke-Engine 'capabilities' @{}; Require ($reply.kind -eq 'result') ($reply|ConvertTo-Json -Depth 5)
    Require ($reply.payload.computeBackends -contains 'system') '系統路徑不存在'
    Require ($reply.payload.rawDecoders -contains 'system' -and $reply.payload.rawDecoders -contains 'software') '未偵測到已附帶的 RAW 模組'
    Require (!$reply.payload.rawDecoderMessage) '不應顯示一般 RAW 說明文字'
    if($reply.payload.computeBackends -contains 'vulkan') {
        Require ([version]$reply.payload.gpu.loaderVersion -ge [version]'1.1' -and [version]$reply.payload.gpu.deviceVersion -ge [version]'1.1') 'Vulkan 版本不相容'
    }
    $script:capabilities=$reply.payload;return $reply.payload
}
Check '中文 JPEG、ICC 與 EXIF 方向縮圖' {
    $reply=Invoke-Engine 'thumbnail' @{path=(Join-Path $Build '中文 橫向.jpg');maxPixel=160}
    Require ($reply.kind -eq 'result') ($reply|ConvertTo-Json -Depth 5)
    Require ($reply.payload.width -eq 100 -and $reply.payload.height -eq 160) 'EXIF 方向或縮圖尺寸不符'
    $bytes=[Convert]::FromBase64String($reply.payload.imageData);Require ($bytes.Length -gt 100) '縮圖內容遺失'
    [IO.File]::WriteAllBytes((Join-Path $output 'thumbnail.jpg'),$bytes)
    return @{width=$reply.payload.width;height=$reply.payload.height;bytes=$bytes.Length}
}
Check '損壞 JPEG 回報錯誤' {
    $reply=Invoke-Engine 'thumbnail' @{path=(Join-Path $Build '破損.jpg');maxPixel=160}
    Require ($reply.kind -eq 'error' -and $reply.error.code -eq 'decodeFailed') '損壞檔案被當成正常照片';return $reply.error
}
Check '原片 JPEG 顯影與常駐快取' {
    $process=Start-Native 'filmdevelop-engine.exe' '--preview-session'
    try {
        $first=Request $process 'preview' (New-Job)
        Require ($first.kind -eq 'result') ($first|ConvertTo-Json -Depth 5)
        $second=Request $process 'preview' (New-Job 'system' 1)
        Require ($second.kind -eq 'result') ($second|ConvertTo-Json -Depth 5)
        Require ($second.payload.timing.sourceCacheHit -and $second.payload.timing.processingCacheHit) '重複預覽沒有共用已解析影像'
        Require ($second.payload.computeRoute -eq $(if($script:capabilities.computeBackends -contains 'vulkan'){'vulkan'}else{'cpu'})) '系統自動選擇未符合探測結果'
        Require ($first.payload.cropImage -ne $second.payload.cropImage) '曝光參數未套用'
        Require ($first.payload.sourceImage -eq $second.payload.sourceImage) '調整污染原圖比較'
        return $second.payload.timing
    } finally {$process.StandardInput.Close();if(!$process.WaitForExit(5000)){$process.Kill()};$process.Dispose()}
}
Check '缺少 GPU 模組時自動使用 CPU' {
    $isolated=Join-Path $Build ('cpu-only-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $isolated | Out-Null
    foreach($name in @('filmdevelop-engine.exe','neutral-recipe.json','style-catalog.json','film-data')) {Copy-Item -LiteralPath (Join-Path $Build $name) -Destination $isolated -Recurse}
    Get-ChildItem -LiteralPath $Build -Filter *.dll | Where-Object Name -NotIn @('libPhotoCompute.dll','fault-compute.dll') | Copy-Item -Destination $isolated
    $process=Start-Native ((Split-Path $isolated -Leaf)+'\filmdevelop-engine.exe')
    try {
        $caps=Request $process 'capabilities' @{}
        Require ($caps.kind -eq 'result' -and $caps.payload.computeBackends.Count -eq 1 -and $caps.payload.computeBackends[0] -eq 'system') '無 GPU 模組時仍提供 Vulkan'
        $process.StandardInput.Close();if(!$process.WaitForExit(5000)){$process.Kill();throw '能力探測未結束'};$process.Dispose()
        $process=Start-Native ((Split-Path $isolated -Leaf)+'\filmdevelop-engine.exe')
        $reply=Request $process 'preview' (New-Job)
        Require ($reply.kind -eq 'result' -and $reply.payload.computeRoute -eq 'cpu') 'CPU 備援沒有產生預覽'
        return @{computeBackends=$caps.payload.computeBackends;computeRoute=$reply.payload.computeRoute}
    } finally {$process.StandardInput.Close();if(!$process.WaitForExit(5000)){$process.Kill()};$process.Dispose()}
}
if(Test-Path (Join-Path $Build 'fault-compute.dll')) {
    foreach($fault in @('old-loader','old-device','bad-probe','render-failure')) {
        Check ('GPU 不可用時完整退回 CPU：'+$fault) {
            $isolated=Join-Path $Build ('gpu-fault-'+[guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $isolated | Out-Null
            foreach($name in @('filmdevelop-engine.exe','neutral-recipe.json','style-catalog.json','film-data')) {Copy-Item -LiteralPath (Join-Path $Build $name) -Destination $isolated -Recurse}
    Get-ChildItem -LiteralPath $Build -Filter *.dll | Where-Object Name -NotIn @('libPhotoCompute.dll','fault-compute.dll') | Copy-Item -Destination $isolated
            Copy-Item -LiteralPath (Join-Path $Build 'fault-compute.dll') -Destination (Join-Path $isolated 'libPhotoCompute.dll')
            $env:FILMDEVELOP_TEST_GPU_FAULT=$fault
            $process=Start-Native ((Split-Path $isolated -Leaf)+'\filmdevelop-engine.exe') '--preview-session'
            try {
                $reply=Request $process 'preview' (New-Job 'system' 1)
                Require ($reply.kind -eq 'result' -and $reply.payload.computeRoute -eq 'cpu') 'GPU 失敗未自動退回 CPU'
                $again=Request $process 'preview' (New-Job 'system' 1)
                Require ($again.kind -eq 'result' -and $again.payload.cropImage -eq $reply.payload.cropImage) '備援影像或快取不一致'
                $explicit=Request $process 'preview' (New-Job 'vulkan' 1)
                Require ($explicit.kind -eq 'error') '明確選擇不可用 GPU 卻被當成成功'
                return @{computeRoute=$reply.payload.computeRoute;reason=$reply.payload.computeFallback}
            } finally {$process.StandardInput.Close();if(!$process.WaitForExit(5000)){$process.Kill()};$process.Dispose();Remove-Item Env:FILMDEVELOP_TEST_GPU_FAULT}
        }
    }
}
if(Test-Path (Join-Path $Build '測試 原片.dng')) {
    Check '內建 LibRaw 實際 DNG 顯影' {
        $job=New-Job;$job.input.path=Join-Path $Build '測試 原片.dng';$job.input.rawDecoder='software'
        $reply=Invoke-Engine 'preview' $job;Require ($reply.kind -eq 'result') ($reply|ConvertTo-Json -Depth 5)
        Require ($reply.payload.rawDecoder -eq 'software' -and $reply.payload.sourceWidth -gt 100) '未使用 LibRaw 解碼'
        return @{sourceWidth=$reply.payload.sourceWidth;sourceHeight=$reply.payload.sourceHeight;rawDecoder=$reply.payload.rawDecoder;timing=$reply.payload.timing}
    }
}
if(Test-Path (Join-Path $Build '測試 原片.NEF')) {
    Check '系統 RAW 實際 NEF 解碼與預覽' {
        $path=Join-Path $Build '測試 原片.NEF';$hash=(Get-FileHash -LiteralPath $path).Hash
        $thumb=Invoke-Engine 'thumbnail' @{path=$path;maxPixel=240}
        Require ($thumb.kind -eq 'result') ($thumb|ConvertTo-Json -Depth 5)
        $job=New-Job;$job.input.path=$path;$job.previewMaxPixel=1024;$job.output.maxPixel=1024
        $reply=Invoke-Engine 'preview' $job;Require ($reply.kind -eq 'result') ($reply|ConvertTo-Json -Depth 5)
        Require ($reply.payload.rawDecoder -in @('system','software') -and $reply.payload.sourceWidth -gt 1024) 'RAW 原圖未正常解碼'
        Require ($hash -eq (Get-FileHash -LiteralPath $path).Hash) '來源 RAW 遭到變更'
        return @{sourceWidth=$reply.payload.sourceWidth;sourceHeight=$reply.payload.sourceHeight;rawDecoder=$reply.payload.rawDecoder;systemRAWFallback=$reply.payload.systemRAWFallback;computeRoute=$reply.payload.computeRoute;timing=$reply.payload.timing}
    }
}
foreach($format in @('png','tiff')) {
    Check ($format+' 16 bit 輸出') {
        $job=New-Job 'system' .5 $format 16;$job.preview=$false
        $reply=Invoke-Engine 'render' $job;Require ($reply.kind -eq 'result') ($reply|ConvertTo-Json -Depth 5)
        Require (Test-Path -LiteralPath $job.output.path) '成品沒有產生'
        $metadata=Invoke-Engine 'metadata' @{path=$job.output.path}
        Require ($metadata.kind -eq 'result' -and $metadata.payload.BitsPerPixel -ge 48) '成品未保持 16 bit 色彩通道'
        $again=Invoke-Engine 'render' $job;Require ($again.kind -eq 'error' -and $again.error.code -eq 'outputExists') '覆寫已存在成品'
        return @{file=$job.output.path;bytes=(Get-Item -LiteralPath $job.output.path).Length;bitsPerPixel=$metadata.payload.BitsPerPixel}
    }
}
Check '未移植調整不會靜默遺漏' {
    $job=New-Job; $job.recipe.adjustment|Add-Member -NotePropertyName unsupportedFutureControl -NotePropertyValue 50
    $reply=Invoke-Engine 'preview' $job;Require ($reply.kind -eq 'error' -and $reply.error.code -eq 'unsupportedParameter') '不支援的效果被當成成功'
    Require (!(Test-Path -LiteralPath $job.output.path)) '失敗工作留下成品';return $reply.error
}
if($capabilities.computeBackends -contains 'vulkan') {
    Check 'Vulkan 曝光、RAW 映射與校色' {Run-Native 'photo_core_vulkan_verify.exe'}
    Check 'Vulkan 錯誤復原與資源釋放' {Run-Native 'photo_core_vulkan_lifetime.exe' 'film.comp.spv'}
    Check 'PhotoCompute 常駐計算圖' {Run-Native 'photo_compute_plan_verify.exe' 'film-data film.comp.spv'}
    Check '原生引擎實際 GPU 預覽' {
        $reply=Invoke-Engine 'preview' (New-Job 'vulkan' 1)
        Require ($reply.kind -eq 'result') ($reply|ConvertTo-Json -Depth 5)
        Require ($reply.payload.computeBackend -eq 'vulkan') '沒有使用所選 GPU 後端';return $reply.payload.timing
    }
}
if(Test-Path (Join-Path $Build 'windows-ui-smoke.exe')) {
    $env:FILMDEVELOP_ENGINE=Join-Path $Build 'filmdevelop-engine.exe'
    $env:FILMDEVELOP_DATA_DIR=Join-Path $output 'ui-data'
    $env:FILMDEVELOP_SMOKE_INPUT=Join-Path $Build '正常.jpg'
    foreach($mode in @('fresh','restore')) {
        Check ('Windows WebView2 UI：'+$mode) {
            $env:FILMDEVELOP_SMOKE_WINDOWS=$mode
            $env:FILMDEVELOP_SMOKE_REPORT=Join-Path $output ('ui-'+$mode+'.json')
            [void](Run-Native 'windows-ui-smoke.exe')
            $ui=Get-Content -Raw -LiteralPath $env:FILMDEVELOP_SMOKE_REPORT -Encoding UTF8|ConvertFrom-Json
            Require $ui.passed ($ui|ConvertTo-Json -Depth 6);return $ui
        }
    }
}
$report=@{schema=1;finishedAtUTC=[DateTime]::UtcNow.ToString('o');checks=$results;passed=(@($results|Where-Object{!$_.passed}).Count -eq 0);output=$output}
$report|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $Build $ReportName) -Encoding UTF8
if(!$report.passed){exit 1}
