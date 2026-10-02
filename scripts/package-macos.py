#!/usr/bin/env python3
"""封裝與 Go 更新器識別相符的 Apple Silicon 混合 DMG；不發布 Release。"""
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile
from windows_resources import ROOT, project_version

version = project_version()
app = ROOT / 'build/desktop/FilmDevelopGo.app'
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleExecutable'] == 'FilmDevelopGo'
assert info['CFBundleShortVersionString'] == version['version'] and info['CFBundleVersion'] == version['build']
assert (app/'Contents/Resources/Engine/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine').is_file()
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
destination = ROOT/'dist/macos-arm64'
destination.mkdir(parents=True,exist_ok=True)
name = f"FilmDevelop-{version['version']}-build{version['build']}-macos-arm64.dmg"
with tempfile.TemporaryDirectory(prefix='filmdevelop-package-',dir=ROOT/'build') as temporary:
    work=Path(temporary);payload=work/'payload';payload.mkdir()
    subprocess.run(['ditto',str(app),str(payload/'FilmDevelop.app')],check=True)
    (payload/'Applications').symlink_to('/Applications',target_is_directory=True)
    output=work/name
    subprocess.run(['hdiutil','create','-volname','FilmDevelop','-srcfolder',str(payload),'-format','UDZO',str(output)],check=True)
    subprocess.run(['hdiutil','verify',str(output)],check=True)
    output.replace(destination/name)
with (destination/name).open('rb') as file:
    hash=hashlib.sha256()
    for block in iter(lambda:file.read(1024*1024),b''): hash.update(block)
    digest=hash.hexdigest()
(destination/'SHA256SUMS').write_text(f'{digest}  {name}\n')
print(destination/name)
