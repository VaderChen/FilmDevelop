#!/usr/bin/env python3
"""從已釘選的 Microsoft 套件準備 x64 app-local Runtime，不安裝或修改系統。"""
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

from windows_payload import PE

ROOT = Path(__file__).resolve().parents[1]


def prepare(destination):
    config = json.loads((ROOT / 'packaging/windows/prerequisites.json').read_text())['visualCppX64']
    cache = ROOT / 'build/parity-ai/VC_redist.x64.exe'
    cache.parent.mkdir(parents=True, exist_ok=True)
    if not cache.is_file():
        with tempfile.NamedTemporaryFile(dir=cache.parent, delete=False) as target:
            temporary = Path(target.name)
            try:
                with urllib.request.urlopen(config['url'], timeout=90) as response:
                    shutil.copyfileobj(response, target)
            except BaseException:
                temporary.unlink(missing_ok=True)
                raise
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != config['sha256']:
            temporary.unlink()
            raise ValueError('Microsoft Runtime 下載雜湊不符')
        temporary.replace(cache)
    data = cache.read_bytes()
    if hashlib.sha256(data).hexdigest() != config['sha256']:
        raise ValueError('Microsoft Runtime 快取雜湊不符')
    sevenzip = shutil.which('7zz') or shutil.which('7z')
    msiextract = shutil.which('msiextract')
    if not sevenzip or not msiextract:
        raise ValueError('準備免安裝 Runtime 需要 7-Zip 與 msiextract（msitools）')
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.vc-runtime-', dir=destination) as work:
        work = Path(work)
        # WiX Burn 含啟動資源及附加 CAB；依 CAB 標頭長度解析，來源由 SHA-256 釘選。
        containers, offset = [], 0
        while True:
            start = data.find(b'MSCF\0\0\0\0', offset)
            if start < 0:
                break
            offset = start + 4
            size = struct.unpack_from('<I', data, start + 8)[0]
            if not 36 <= size <= len(data) - start:
                continue
            cabinet = work / f'{len(containers)}.cab'
            cabinet.write_bytes(data[start:start + size])
            folder = work / f'container-{len(containers)}'
            subprocess.run([sevenzip, 'x', '-y', f'-o{folder}', str(cabinet)],
                           stdout=subprocess.DEVNULL, check=True)
            containers.append(folder)
        manifests = [p / '0' for p in containers if (p / '0').is_file()]
        if len(manifests) != 1:
            raise ValueError('Microsoft Runtime 缺少唯一的套件清單')
        manifest = ET.fromstring(manifests[0].read_bytes())
        payload = work / 'msi'
        payload.mkdir()
        for entry in manifest.iter():
            if not entry.tag.endswith('Payload') or not entry.get('FilePath', '').startswith('packages\\vcRuntimeMinimum_amd64\\'):
                continue
            sources = [p / entry.attrib['SourcePath'] for p in containers if (p / entry.attrib['SourcePath']).is_file()]
            if len(sources) != 1:
                raise ValueError('Microsoft Runtime 來源內容不符')
            content = sources[0].read_bytes()
            if len(content) != int(entry.attrib['FileSize']) or hashlib.sha1(content).hexdigest() != entry.attrib['Hash'].lower():
                raise ValueError('Microsoft Runtime 內部套件雜湊不符')
            (payload / entry.attrib['FilePath'].split('\\')[-1]).write_bytes(content)
        expanded = work / 'expanded'
        subprocess.run([msiextract, '-C', str(expanded), str(payload / 'vc_runtimeMinimum_x64.msi')],
                       stdout=subprocess.DEVNULL, check=True)
        files = sorted(expanded.rglob('*.dll'))
        if not set(config['dlls']).issubset({p.name for p in files}):
            raise ValueError('Microsoft Runtime 缺少必要的 DLL')
        entries = []
        for file in files:
            pe = PE(file)
            if pe.machine != 0x8664 or pe.magic != 0x20b or not pe.directory(4)[1]:
                raise ValueError(f'Runtime 必須是附原廠簽章的 x64 DLL：{file.name}')
            version, _, _ = pe.version()
            if tuple(map(int, version.split('.'))) < tuple(map(int, config['minimumVersion'].split('.'))):
                raise ValueError(f'Runtime 版本過舊：{file.name}')
            target = destination / 'bin' / file.name
            target.parent.mkdir(exist_ok=True)
            shutil.copy2(file, target)
            entries.append({'path': file.name, 'version': version,
                            'sha256': hashlib.sha256(file.read_bytes()).hexdigest()})
        licenses = destination / 'Licenses'
        licenses.mkdir(exist_ok=True)
        provenance = {'source': config['url'], 'sha256': config['sha256'], 'files': entries}
        (licenses / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
        (licenses / 'README.txt').write_text(
            'Microsoft Visual C++ x64 Runtime\nCopyright Microsoft Corporation.\n\n'
            '原廠 DLL 未修改，來源及 SHA-256 見 provenance.json。僅供本程式 app-local 使用，\n'
            '不寫入 Windows 系統目錄；使用及散布遵循 Microsoft Software License Terms。\n'
            'https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files\n'
            'https://visualstudio.microsoft.com/license-terms/\n', encoding='utf-8')
    print(f'Windows x64 app-local Runtime 已驗證：{len(entries)} 個原廠 DLL')


if __name__ == '__main__':
    prepare(Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'build/windows-cross/vc-runtime')
