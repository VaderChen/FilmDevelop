#!/usr/bin/env python3
"""準備釘選版本的 Windows x64 ONNX Runtime／DirectML 與對應授權。"""
import hashlib
from pathlib import Path
import shutil
import sys
import urllib.request
import zipfile

PACKAGES = [
    ('microsoft.ml.onnxruntime.directml', '1.24.4', '57e9f11b73437bef7a309496135d4c1f96b1a8e9ddba60013fa27bfc1d788681'),
    ('microsoft.ai.directml', '1.15.4', '4e7cb7ddce8cf837a7a75dc029209b520ca0101470fcdf275c1f49736a3615b9'),
]
root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1] if len(sys.argv) > 1 else root/'build/windows-cross/neural')
cache = root/'build/parity-ai'
cache.mkdir(parents=True, exist_ok=True)
for name, version, expected in PACKAGES:
    archive = cache/f'{name}.{version}.nupkg'
    if not archive.is_file():
        url = f'https://api.nuget.org/v3-flatcontainer/{name}/{version}/{archive.name}'
        temporary = archive.with_suffix('.part')
        with urllib.request.urlopen(url, timeout=90) as response, temporary.open('wb') as target:
            shutil.copyfileobj(response, target)
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        raise ValueError(f'原生推論套件雜湊不符：{archive.name}')
    with zipfile.ZipFile(archive) as package:
        for item in package.namelist():
            path = Path(item)
            target = None
            if (item.startswith('build/native/include/') or item.startswith('include/')) and path.suffix == '.h':
                target = out/'include'/path.name
            elif item in ('runtimes/win-x64/native/onnxruntime.dll', 'runtimes/win-x64/native/onnxruntime_providers_shared.dll', 'bin/x64-win/DirectML.dll'):
                target = out/'bin'/path.name
            elif path.name.lower().startswith(('license', 'thirdpartynotices')):
                target = out/'Licenses'/name/path.name
            if target:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(package.read(item))
print(f'Windows 原生推論相依已驗證：{out}')
