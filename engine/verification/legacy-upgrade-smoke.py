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
import shutil
import signal

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--legacy-app', type=Path, required=True)
parser.add_argument('--dmg', type=Path, required=True)
parser.add_argument('--version', required=True)
parser.add_argument('--build', required=True)
parser.add_argument('--expect-migration', action='store_true')
parser.add_argument('--data-source', type=Path)
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
gui_pid = None
if args.data_source:
    shutil.copytree(args.data_source, out/'data')
else:
    (out/'data').mkdir()
(out/'data/identity-migration-sentinel.txt').write_text('既有使用者資料必須保留\n')
def data_hashes():
    return {str(p.relative_to(out/'data')): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (out/'data').rglob('*') if p.is_file() and p.relative_to(out/'data').as_posix() != 'state/updates.json'}
before_data = data_hashes()
def app_process():
    prefix = str(target/'Contents/MacOS/FilmDevelopGo')
    lines = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
    matches = [int(line.strip().split(None, 1)[0]) for line in lines
               if len(line.strip().split(None, 1)) == 2 and line.strip().split(None, 1)[1].startswith(prefix)]
    assert len(matches) <= 1, '隔離 App 不應重複啟動'
    return matches[0] if matches else None
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
        if args.expect_migration:
            assert process.wait(timeout=60) == 0, '過渡啟動器失敗'
            deadline = time.monotonic()+60
            while time.monotonic()<deadline:
                try:
                    current_info = plistlib.loads((target/'Contents/Info.plist').read_bytes())
                    state = json.loads((out/'data/state/updates.json').read_text())
                    gui_pid = app_process()
                    if current_info['CFBundleIdentifier']=='person.vader.FilmDevelop.GoDevelopment' and state.get('last')==release['tag_name'] and gui_pid:
                        break
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                time.sleep(.2)
            else:
                raise AssertionError('未完成標準 App 替換與 GUI 啟動')
        else:
            deadline = time.monotonic()+30
            while time.monotonic()<deadline and process.poll() is None and not (work/'confirmed').is_file():
                time.sleep(.2)
            assert process.poll() is None, '升級後 GUI 未持續執行'
        assert (work/'confirmed').is_file(), '未確認舊 Swift 更新收據'
        time.sleep(5)
        state = json.loads((out/'data/state/updates.json').read_text())
        assert state['last']==release['tag_name'] and state['pending']==release['tag_name']
        if args.expect_migration:
            assert app_process()==gui_pid, '標準 GUI 未持續執行'
            subprocess.run(['codesign','--verify','--deep','--strict',str(target)],check=True)
            subprocess.run(['spctl','--assess','--type','execute',str(target)],check=True)
            assert not (target/'Contents/Resources/Migration').exists(), '過渡啟動器未移除'
            leftovers = [p for p in out.glob('.FilmYourPhoto-*') if p != backup]
            assert not leftovers, '移轉未確認或暫存未清理'
            after_data = data_hashes()
            assert all(after_data.get(k)==v for k,v in before_data.items()), '既有使用者資料被修改'
            # 再開標準 App，不應重新移轉或需要相容包。
            os.kill(gui_pid, signal.SIGTERM)
            deadline = time.monotonic()+10
            while app_process() and time.monotonic()<deadline: time.sleep(.2)
            gui_pid = None
            process = subprocess.Popen([str(target/'Contents/MacOS/FilmDevelopGo')],env=env,stdout=log,stderr=log)
            time.sleep(5)
            assert process.poll() is None
            assert plistlib.loads((target/'Contents/Info.plist').read_bytes())['CFBundleIdentifier']=='person.vader.FilmDevelop.GoDevelopment'
            assert all(data_hashes().get(k)==v for k,v in before_data.items())
    report = {'passed': True, 'legacySelection': True, 'legacyDigestAndSignaturePreparation': True,
              'goReceiptConfirmed': True, 'isolatedGUIStartup': True, 'identityMigrated': args.expect_migration,
              'preservedDataFiles': len(before_data), 'standardAppRestart': args.expect_migration, 'version': args.version,
              'build': args.build, 'asset': name, 'sha256': digest,
              'scope': ('舊 Swift 選包與暫存、過渡包啟動、實際安裝 helper 替換並啟動標準 App、再次開啟；使用隔離資料' if args.expect_migration else '舊 Swift 選包與暫存、同磁碟替換、新版 Go 直接啟動確認；未改動使用中的 App')}
    (out/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({'passed': True, 'report': str(out/'report.json')}, ensure_ascii=False))
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        process.wait(timeout=15)
    if gui_pid is not None:
        try: os.kill(gui_pid, signal.SIGTERM)
        except ProcessLookupError: pass
    # 保留隔離副本及報告；macOS 暫存只含本次工具建立的收據與 helper。
    import shutil
    shutil.rmtree(work)
