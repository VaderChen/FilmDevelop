#!/usr/bin/env python3
"""在隔離資料目錄量測真實桌面的照片／底片切換，不修改來源照片。"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('photos',nargs=2,type=Path)
parser.add_argument('--report',required=True,type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parents[2]
out=Path(tempfile.mkdtemp(prefix='preview-navigation-',dir=root/'build'))
directory=out/'照片';directory.mkdir()
for i,path in enumerate(args.photos):
    shutil.copy2(path,directory/(str(i+1)+path.suffix))
binary=out/'FilmDevelopNavigationSmoke'
subprocess.run(['python3',str(root/'scripts/prepare-desktop.py')],check=True)
subprocess.run(['go','-C',str(root/'desktop'),'build','-tags','desktop,production,enginesmoke','-o',str(binary),'./cmd/filmdevelop-desktop'],check=True)
env=dict(os.environ,FILMDEVELOP_ENGINE=str(root/'build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine'),
         FILMDEVELOP_DATA_DIR=str(out/'data'),FILMDEVELOP_SMOKE_REPORT=str(out/'report.json'),
         FILMDEVELOP_SMOKE_DIRECTORY=str(directory),FILMDEVELOP_SMOKE_NAVIGATION='1')
with (out/'stdout.log').open('w') as stdout,(out/'stderr.log').open('w') as stderr:
    subprocess.run([str(binary)],env=env,stdout=stdout,stderr=stderr,timeout=180,check=True)
report=json.loads((out/'report.json').read_text())
assert report['passed'],report
report['sources']=[str(path) for path in args.photos]
report['runDirectory']=str(out)
args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'passed':True,'report':str(args.report),'results':report['results']},ensure_ascii=False))
