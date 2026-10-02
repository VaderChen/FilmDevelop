#!/usr/bin/env python3
"""使用既有圖示與專案版本，建置含 Windows 資源的 x64 Go 桌面程式。"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def project_version():
    project = (ROOT / 'PhotoStyleApp.xcodeproj/project.pbxproj').read_text()
    versions = set(re.findall(r'MARKETING_VERSION = ([0-9.]+);', project))
    builds = set(re.findall(r'CURRENT_PROJECT_VERSION = ([0-9]+);', project))
    if len(versions) != 1 or len(builds) != 1:
        raise ValueError('專案版本設定不一致，無法產生 Windows 版本資訊')
    version, build = versions.pop(), builds.pop()
    components = [int(value) for value in version.split('.')] + [int(build)]
    if len(components) != 4 or any(not 0 <= value <= 65535 for value in components):
        raise ValueError('Windows 版本需要四段 0～65535 整數')
    return {'version': version, 'build': build, 'numericVersion': '.'.join(map(str, components)),
            'displayVersion': f'{version} build {build} Beta',
            'architecture': 'x64', 'fullWindowsRendererAvailable': True}


def make_icon(destination):
    # 直接將既有各尺寸 PNG 放入 ICO 容器，保留像素與透明度，不重繪品牌圖示。
    icons = ROOT / 'PhotoStyleApp/Assets.xcassets/AppIcon.appiconset'
    sources = [(16, '16@1x'), (32, '32@1x'), (64, '32@2x'), (128, '128@1x'), (256, '256@1x')]
    entries, images = [], []
    offset = 6 + len(sources) * 16
    for size, suffix in sources:
        data = (icons / f'AppIcon-mac-{suffix}.png').read_bytes()
        if data[:8] != b'\x89PNG\r\n\x1a\n' or struct.unpack_from('>II', data, 16) != (size, size):
            raise ValueError(f'原有圖示尺寸不符：{suffix}')
        entries.append(struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), offset))
        images.append(data)
        offset += len(data)
    destination.write_bytes(struct.pack('<HHH', 0, 1, len(entries)) + b''.join(entries + images))


def build(output, resources):
    windres = shutil.which('x86_64-w64-mingw32-windres')
    if not windres:
        raise ValueError('缺少 x86_64-w64-mingw32-windres')
    info = project_version()
    resources.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    make_icon(resources / 'FilmDevelop.ico')
    manifest = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity type="win32" name="person.vader.FilmDevelop" version="{info['numericVersion']}" processorArchitecture="amd64"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges><requestedExecutionLevel level="asInvoker" uiAccess="false"/></requestedPrivileges></security></trustInfo>
  <dependency><dependentAssembly><assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/></dependentAssembly></dependency>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"><application><supportedOS Id="{{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}}"/></application></compatibility>
  <application xmlns="urn:schemas-microsoft-com:asm.v3"><windowsSettings>
    <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
    <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2,PerMonitor</dpiAwareness>
    <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
  </windowsSettings></application>
</assembly>
'''
    (resources / 'FilmDevelop.exe.manifest').write_text(manifest)
    numeric = info['numericVersion'].replace('.', ',')
    rc = f'''#pragma code_page(65001)
#include <windows.h>
1 ICON "FilmDevelop.ico"
1 RT_MANIFEST "FilmDevelop.exe.manifest"
1 VERSIONINFO
FILEVERSION {numeric}
PRODUCTVERSION {numeric}
FILEFLAGSMASK VS_FFI_FILEFLAGSMASK
FILEFLAGS 0
FILEOS VOS_NT_WINDOWS32
FILETYPE VFT_APP
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040404B0"
    BEGIN
      VALUE "CompanyName", "VaderChen\\0"
      VALUE "FileDescription", "FilmDevelop\\0"
      VALUE "FileVersion", "{info['displayVersion']}\\0"
      VALUE "InternalName", "FilmDevelop\\0"
      VALUE "OriginalFilename", "FilmDevelop.exe\\0"
      VALUE "ProductName", "FilmDevelop\\0"
      VALUE "ProductVersion", "{info['displayVersion']}\\0"
      VALUE "LegalCopyright", "Copyright 2026 VaderChen\\0"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x0404, 1200
  END
END
'''
    (resources / 'FilmDevelop.rc').write_text(rc)
    resource = ROOT / 'desktop/cmd/filmdevelop-desktop/resource_windows_amd64.syso'
    # 與 YourDesk 相同，只在編譯期間放置 Go 自動連結的資源；不覆蓋既有檔案。
    if resource.exists():
        raise ValueError(f'資源檔已存在，請先確認是否有其他建置正在執行：{resource}')
    resource.touch(exist_ok=False)
    try:
        subprocess.run([windres, '--codepage=65001', '-i', 'FilmDevelop.rc', '-O', 'coff', '-o', str(resource)],
                       cwd=resources, check=True)
        with tempfile.TemporaryDirectory(prefix='.filmdevelop-gui-', dir=output.parent) as temporary:
            binary = Path(temporary) / output.name
            env = dict(os.environ, GOOS='windows', GOARCH='amd64', CGO_ENABLED='0')
            subprocess.run(['go', '-C', str(ROOT / 'desktop'), 'build', '-trimpath', '-tags', 'desktop,production',
                            '-ldflags', '-H windowsgui', '-o', str(binary), './cmd/filmdevelop-desktop'], env=env, check=True)
            os.replace(binary, output)
    finally:
        resource.unlink()
    (resources / 'build-info.json').write_text(json.dumps(info, ensure_ascii=False, indent=2) + '\n')
    print(f'已嵌入 Windows x64 圖示、Manifest 與版本：{info["displayVersion"]}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--resources', type=Path, required=True)
    args = parser.parse_args()
    build(args.output.resolve(), args.resources.resolve())
