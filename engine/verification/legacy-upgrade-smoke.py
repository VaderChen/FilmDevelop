#!/usr/bin/env python3
"""用舊 Swift 選包／暫存流程及新版 Go 啟動收據，驗證隔離副本升級。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--legacy-app', type=Path, required=True)
parser.add_argument('--dmg', type=Path, required=True)
parser.add_argument('--version', required=True)
parser.add_argument('--build', required=True)
args = parser.parse_args()
out = Path(tempfile.mkdtemp(prefix='legacy-upgrade-smoke-', dir=root/'build'))
binary = out/'legacy-updater-smoke'
subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library',
                str(root/'PhotoStyleApp/PhotoAppRelease.swift'),
                str(root/'PhotoStyleApp/PhotoAppUpdateInstaller.swift'),
                str(root/'engine/verification/legacy-updater-smoke.swift'), '-o', str(binary)], check=True)
digest = hashlib.sha256(args.dmg.read_bytes()).hexdigest()
name = f'FilmYourPhoto-{args.version}-build-{args.build}-arm64.dmg'
assert args.dmg.name == name
release = {'tag_name': f'v{args.version}-build-{args.build}', 'draft': False, 'prerelease': False,
           'assets': [{'name': name, 'size': args.dmg.stat().st_size, 'state': 'uploaded',
                       'digest': 'sha256:'+digest,
                       'url': 'https://api.github.com/repos/VaderChen/FilmDevelop/releases/assets/1'}]}
(out/'release.json').write_text(json.dumps(release))
target = out/'FilmYourPhoto.app'
subprocess.run(['ditto', str(args.legacy_app), str(target)], check=True)
# 使用與舊更新器相同的暫存根與前綴；只操作測試副本。
work = Path(tempfile.mkdtemp(prefix='FilmYourPhoto-update-')).resolve()
process = None
try:
    prepared = json.loads(subprocess.check_output([str(binary), 'prepare', str(out/'release.json'),
                          str(target), str(args.dmg.resolve()), str(work)], text=True))
    staged, backup = Path(prepared['staged']), Path(prepared['backup'])
    info = plistlib.loads((staged/'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier']=='person.vader.PhotoStyleApp'
    assert info['CFBundleExecutable']=='FilmDevelopGo'
    assert info['CFBundleShortVersionString']==args.version and info['CFBundleVersion']==args.build
    # 與安裝 helper 相同的同磁碟替換順序，直接啟動以指定隔離資料目錄。
    target.rename(backup)
    staged.rename(target)
    env = dict(os.environ, FILMDEVELOP_DATA_DIR=str(out/'data'))
    with (out/'gui.log').open('w') as log:
        process = subprocess.Popen([str(target/'Contents/MacOS/FilmDevelopGo'), '--finish-update', str(work)],
                                   env=env, stdout=log, stderr=log)
        deadline = time.monotonic()+30
        while time.monotonic()<deadline and process.poll() is None and not (work/'confirmed').is_file():
            time.sleep(.2)
        assert (work/'confirmed').is_file(), 'Go 未確認舊 Swift 更新收據'
        time.sleep(5)
        assert process.poll() is None, '升級後 GUI 未持續執行'
        state = json.loads((out/'data/state/updates.json').read_text())
        assert state['last']==release['tag_name'] and state['pending']==release['tag_name']
    report = {'passed': True, 'legacySelection': True, 'legacyDigestAndSignaturePreparation': True,
              'goReceiptConfirmed': True, 'isolatedGUIStartup': True, 'version': args.version,
              'build': args.build, 'asset': name, 'sha256': digest,
              'scope': '舊 Swift 選包與暫存、同磁碟替換、新版 Go 直接啟動確認；未改動使用中的 App'}
    (out/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({'passed': True, 'report': str(out/'report.json')}, ensure_ascii=False))
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        process.wait(timeout=15)
    # 保留隔離副本及報告；macOS 暫存只含本次工具建立的收據與 helper。
    import shutil
    shutil.rmtree(work)
