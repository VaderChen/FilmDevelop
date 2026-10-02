#!/usr/bin/env python3
"""以真實 Wails 視窗與原有前端，驗證 Go／Swift 編輯、匯出及紀錄恢復。"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root=Path(__file__).resolve().parents[2]
previous=json.loads((root/'build/engine-smoke-latest.json').read_text())
source=Path(previous['report']).parent/'來源照片.bmp'
out=Path(tempfile.mkdtemp(prefix='desktop-smoke-',dir=root/'build'))
directory=out/'繁體中文 照片目錄';directory.mkdir()
first=directory/'photo2.bmp';first.write_bytes(source.read_bytes())
second=bytearray(source.read_bytes());second[-12]^=127
(directory/'photo10.bmp').write_bytes(second)
(directory/'zz-invalid.jpg').write_bytes(b'broken image')
(directory/'.hidden.png').write_bytes(b'hidden')
(directory/'notes.txt').write_text('略過非影像檔案')
(directory/'nested.png').mkdir()
empty=out/'空目錄';empty.mkdir()
binary=out/'FilmDevelopGoSmoke'
subprocess.run(['python3',str(root/'scripts/prepare-desktop.py')],check=True)
subprocess.run(['go','-C',str(root/'desktop'),'build','-race','-tags','desktop,production,enginesmoke','-o',str(binary),'./cmd/filmdevelop-desktop'],check=True)
env=dict(os.environ,FILMDEVELOP_ENGINE=str(root/'build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine'),
         FILMDEVELOP_DATA_DIR=str(out/'data'),FILMDEVELOP_SMOKE_REPORT=str(out/'report.json'),
         FILMDEVELOP_SMOKE_INPUT=str(first),FILMDEVELOP_SMOKE_OUTPUT=str(out/'export.png'),
         FILMDEVELOP_SMOKE_DIRECTORY=str(directory),FILMDEVELOP_SMOKE_EMPTY=str(empty))
with (out/'stdout.log').open('w') as stdout, (out/'stderr.log').open('w') as stderr:
    subprocess.run([str(binary)],env=env,stdout=stdout,stderr=stderr,timeout=240,check=True)
report=json.loads((out/'report.json').read_text())
assert report['passed'],report
assert (out/'export.png').stat().st_size>0
assert list((out/'data/photos').glob('*.json'))
assert 'DATA RACE' not in (out/'stderr.log').read_text()
closing=report['closeSaved']
saved=[json.loads(p.read_text()) for p in (out/'data/photos').glob('*.json')]
assert any(doc['selected']==closing['style'] and doc['recipes'][closing['style']]['adjustment']['intensity']==closing['intensity'] for doc in saved), '關閉視窗遺失尚未送出的滑桿調整'
report['completed'].append('關閉視窗提交前端暫存調整並寫入照片紀錄')
(out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'passed':True,'report':str(out/'report.json')},ensure_ascii=False))
