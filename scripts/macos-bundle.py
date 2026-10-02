#!/usr/bin/env python3
"""使用既有版本與圖示，設定 Go macOS 桌面套件。"""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

from windows_resources import ROOT, project_version

app = Path(sys.argv[1]).resolve()
version = project_version()
contents = app / 'Contents'
resources = contents / 'Resources'
resources.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='filmdevelop-icon-') as temporary:
    iconset = Path(temporary) / 'FilmDevelop.iconset'
    iconset.mkdir()
    source = ROOT / 'PhotoStyleApp/Assets.xcassets/AppIcon.appiconset'
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = '@2x' if scale == 2 else ''
            shutil.copyfile(source / f'AppIcon-mac-{size}@{scale}x.png',
                            iconset / f'icon_{size}x{size}{suffix}.png')
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'FilmDevelop.icns')], check=True)
info = {
    # 保留已存在的套件識別，避免影響先前授予的系統權限。
    'CFBundleIdentifier': 'person.vader.FilmDevelop.GoDevelopment',
    'CFBundleName': 'FilmDevelop', 'CFBundleDisplayName': 'FilmDevelop',
    'CFBundleExecutable': 'FilmDevelopGo', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': version['version'], 'CFBundleVersion': version['build'],
    'CFBundleIconFile': 'FilmDevelop.icns', 'LSMinimumSystemVersion': '14.0',
    'NSHighResolutionCapable': True,
}
with (contents / 'Info.plist').open('wb') as file:
    plistlib.dump(info, file)
