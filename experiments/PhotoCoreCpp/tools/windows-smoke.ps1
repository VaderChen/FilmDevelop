param([string]$Build = "$PSScriptRoot\..\..\..\build\photocore-cpp-windows\Release",
      [string]$Reference = "$PSScriptRoot\..\..\..\build\photocore-cpp\swift-reference.txt")
$ErrorActionPreference = 'Stop'
# MSVC 多組態產物預設置於 Release；測試 ZIP 可用 -Build . -Reference .\swift-reference.txt。
& "$Build\photo_core_verify.exe" $Reference
if ($LASTEXITCODE -ne 0) { throw '核心／Swift 參考比對失敗' }
$Output = Join-Path $env:TEMP ('photocore-' + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $Output | Out-Null
try {
    & "$Build\photo_core_test.exe" --generate --ev 0.7 --protect-peak --raw-map --output "$Output\result.pfm" --preview "$Output\preview.ppm"
    if ($LASTEXITCODE -ne 0) { throw '影像處理失敗' }
    & "$Build\photo_core_test.exe" --input "$Output\result.pfm" --output "$Output\roundtrip.pfm"
    if ($LASTEXITCODE -ne 0) { throw '影像往返失敗' }
    if ((Get-FileHash "$Output\result.pfm").Hash -ne (Get-FileHash "$Output\roundtrip.pfm").Hash) { throw '零調整改變像素' }
    Write-Output 'PASS: Windows x64 核心、參考值與影像檔案 Smoke'
} finally { Remove-Item -Recurse -Force $Output }
