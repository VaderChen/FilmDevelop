#!/usr/bin/env python3
"""隔離資料，量測真實滑桿並驗證加速設定重啟持久化。"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('photo', type=Path)
parser.add_argument('--report', required=True, type=Path)
parser.add_argument('--preferences', action='store_true')
parser.add_argument('--verify', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
out = Path(tempfile.mkdtemp(prefix='editing-preview-', dir=root/'build'))
directory = out/'照片'
directory.mkdir()
shutil.copy2(args.photo, directory/args.photo.name)
binary = out/'FilmDevelopEditingSmoke'
subprocess.run(['python3', str(root/'scripts/prepare-desktop.py')], check=True)
subprocess.run(['go', '-C', str(root/'desktop'), 'build', '-tags', 'desktop,production,enginesmoke', '-o', str(binary), './cmd/filmdevelop-desktop'], check=True)
reports = []
for mode in (['preferences', 'restore'] if args.preferences else ['verify' if args.verify else 'performance']):
    target = out/(mode+'.json')
    env = dict(os.environ, FILMDEVELOP_ENGINE=str(root/'build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine'),
               FILMDEVELOP_DATA_DIR=str(out/'data'), FILMDEVELOP_SMOKE_REPORT=str(target),
               FILMDEVELOP_SMOKE_DIRECTORY=str(directory), FILMDEVELOP_SMOKE_EDITING=mode)
    with (out/(mode+'.stdout.log')).open('w') as stdout, (out/(mode+'.stderr.log')).open('w') as stderr:
        subprocess.run([str(binary)], env=env, stdout=stdout, stderr=stderr, timeout=180, check=True)
    report = json.loads(target.read_text())
    assert report['passed'], report
    reports.append(report)
result = {'passed': True, 'source': str(args.photo), 'runDirectory': str(out), 'runs': reports}
args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
print(json.dumps(result, ensure_ascii=False))
