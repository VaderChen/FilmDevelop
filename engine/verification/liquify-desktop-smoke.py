#!/usr/bin/env python3
"""以隔離資料目錄啟動真實 Go/WKWebView/Swift App，驗證液化、保存與匯出。"""
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
out = Path(tempfile.mkdtemp(prefix='liquify-desktop-', dir=root/'build'))
fixture = out/'格線照片.bmp'
# 非預覽尺寸的格線，驗證正式匯出仍使用原尺寸。
w, h = 1536, 1024
row = (w*3+3)//4*4
pixels = bytearray(row*h)
for y in range(h):
    for x in range(w):
        i = y*row+x*3
        pixels[i:i+3] = bytes((255,255,255) if x%48<3 or y%48<3 else (80+x*80//w,100+y*100//h,180))
fixture.write_bytes(b'BM'+struct.pack('<IHHI',54+len(pixels),0,0,54)+struct.pack('<IiiHHIIiiII',40,w,h,1,24,0,len(pixels),2835,2835,0,0)+pixels)
subprocess.run(['python3',str(root/'scripts/prepare-desktop.py')],check=True)
binary = out/'FilmDevelopLiquifySmoke'
subprocess.run(['go','-C',str(root/'desktop'),'build','-race','-tags','desktop,production,enginesmoke','-o',str(binary),'./cmd/filmdevelop-desktop'],check=True)
reports = []
for mode in ('edit','restore'):
    folder = out/mode
    folder.mkdir()
    env = dict(os.environ,FILMDEVELOP_ENGINE=str(root/'build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine'),
        FILMDEVELOP_DATA_DIR=str(out/'data'),FILMDEVELOP_SMOKE_REPORT=str(folder/'report.json'),
        FILMDEVELOP_SMOKE_INPUT=str(fixture),FILMDEVELOP_SMOKE_OUTPUT=str(folder/'output.png'),
        FILMDEVELOP_SMOKE_LIQUIFY=mode)
    with (folder/'stdout.log').open('w') as stdout, (folder/'stderr.log').open('w') as stderr:
        subprocess.run([str(binary)],env=env,stdout=stdout,stderr=stderr,timeout=210,check=True)
    report = json.loads((folder/'report.json').read_text())
    assert report['passed'], report
    assert 'DATA RACE' not in (folder/'stderr.log').read_text()
    encoded = (folder/'output.png').read_bytes()
    assert encoded[:8] == b'\x89PNG\r\n\x1a\n'
    assert struct.unpack('>II',encoded[16:24]) == (w,h), '液化匯出沒有保留原尺寸'
    reports.append(report)
assert reports[0]['liquifyRevision'] == reports[1]['liquifyRevision'], '重新啟動液化資料改變'
assert (out/'edit/output.png').read_bytes() == (out/'restore/output.png').read_bytes(), '保存重開後成品不同'
report = {'passed':True,'runs':reports,'checks':['原尺寸1536×1024匯出','重新啟動前後PNG逐位元組相同','未偵測Go資料競爭'],'evidence':str(out)}
(out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'passed':True,'report':str(out/'report.json')},ensure_ascii=False))
