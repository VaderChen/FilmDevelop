#!/usr/bin/env python3
"""以未修改的 Swift 處理器產生多尺寸外框與貼片參考；拒絕覆寫既有基準。"""
import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import time
import zlib

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--engine', type=Path, default=ROOT/'build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine')
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
if (out/'reference-manifest.json').exists():
    raise SystemExit('已有參考基準，請使用新的輸出目錄。')

catalog = json.loads((ROOT/'desktop/internal/recipes/catalog.json').read_text())
base = {s['id']: s for s in catalog['styles']}
cases = []

def png(name, width, height, pixels, channels=3):
    def chunk(kind, data):
        return struct.pack('>I', len(data))+kind+data+struct.pack('>I', zlib.crc32(kind+data)&0xffffffff)
    raw = bytes(pixels)
    scan = b''.join(b'\0'+raw[y*width*channels:(y+1)*width*channels] for y in range(height))
    data = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2 if channels==3 else 0, 0, 0, 0))+chunk(b'IDAT', zlib.compress(scan))+chunk(b'IEND', b'')
    (out/(name+'.png')).write_bytes(data)
    return data

subprocess.run(['sips', '-Z', '1024', str(ROOT/'images/test.jpg'), '-s', 'format', 'png', '--out', str(out/'photo.png')], check=True, stdout=subprocess.DEVNULL)
# 不對稱彩色斜坡、硬邊與奇數尺寸，暴露插值、座標及預乘 alpha 的偏差。
png('edges', 737, 493, (v for y in range(493) for x in range(737) for v in
    ((x*255)//736, (y*255)//492, 220 if (x//13+y//17)%2 else 25)))
shutil.copy2(out/'edges.png', out/'input.png')
for source in ['photo', 'edges']:
    for frame in ['whitePaperThin','whitePaperWide','whitePaperPolaroid','blackLine','filmStrip','cleanInset']:
        case = copy.deepcopy(base['original'])
        case.update(case=source+'-frame-'+frame, input=source+'.pfm', inputPNG=source+'.png')
        case['adjustment'].update(frameEnabled=True, frameStyle=frame)
        cases.append(case)

patch_bytes = png('patch', 63, 47, (v for y in range(47) for x in range(63) for v in (30+x*3, 180-y*2, 220 if (x//7+y//5)%2 else 20)))
mask_bytes = png('mask', 63, 47, [255]*(63*47), 1)
patch = dict(id='6BA7B810-9DAD-41D1-80B4-00C04FD430C8', x=.18, y=.21, width=.42, height=.37,
             linearGain=1.2, imageData=base64.b64encode(patch_bytes).decode(), maskData=base64.b64encode(mask_bytes).decode())
for rotation in [-31, -17, 0, 13.5, 37]:
    case = copy.deepcopy(base['original'])
    case.update(case='repair-hard-'+str(rotation), input='edges.pfm', inputPNG='edges.png',
                repairPatches=[copy.deepcopy(patch)], patchPixels=[dict(image='patch.pfm', mask='mask.pfm')])
    case['adjustment'].update(cropAspectRatio='oneOne', cropRotation=rotation, cropScale=84)
    cases.append(case)
for source in ['photo', 'edges']:
    case = copy.deepcopy(base['gr3-negative'])
    second = dict(patch, id='6BA7B810-9DAD-41D1-80B4-00C04FD430C9', x=.43, y=.37, width=.33, height=.24, linearGain=.7)
    case.update(case=source+'-repair-overlap', input=source+'.pfm', inputPNG=source+'.png',
                repairPatches=[copy.deepcopy(patch), second], patchPixels=[dict(image='patch.pfm', mask='mask.pfm')]*2)
    case['adjustment'].update(cropAspectRatio='threeTwo', cropRotation=12.75, cropScale=91)
    cases.append(case)

cases.insert(0, copy.deepcopy(base['original']))
(out/'cases.json').write_text(json.dumps(dict(catalog, styles=cases), ensure_ascii=False)+'\n')
report = []
for case in cases:
    name = case.get('case', case['id'])
    job = dict(input=dict(path=str(out/case.get('inputPNG','input.png')), rawDecoder='system', lensCorrection=False),
        output=dict(path=str(out/(name+'.png')), format='png', bitDepth=16, colorSpace='sRGB', quality=.95, maxPixel=0, webPLossless=False, tiffCompression=1),
        recipe=dict(version=1, style=case['id'], adjustment=case['adjustment'], repairPatches=case.get('repairPatches',[]), detectSubject=False),
        computeBackend='system', preview=True, previewMaxPixel=2048,
        policy=dict(highlightProtection=True, modernExposure=False, hdr=True, fullResolution=False))
    start=time.monotonic()
    process=subprocess.run([str(args.engine)], input=json.dumps(dict(id=name, version=1, method='preview', payload=job))+'\n', text=True, capture_output=True, timeout=120)
    replies=[json.loads(line) for line in process.stdout.splitlines() if line.startswith('{')]
    assert process.returncode==0 and replies[-1]['kind']=='result', (name, replies[-1:] or process.stderr)
    row=dict(case=name, seconds=time.monotonic()-start, passed=True)
    report.append(row); print(json.dumps(row), flush=True)
subprocess.run(['swift',str(ROOT/'engine/verification/png-to-pfm.swift'), *[str(out/(c.get('case',c['id'])+'.png')) for c in cases]],check=True)
subprocess.run(['swift',str(ROOT/'engine/verification/png-to-pfm.swift'),'--source', *[str(out/(s+'.png')) for s in ['input','photo','edges','patch']]],check=True)
# 遮罩以線性資料解讀，不可使用 PNG 的預設 sRGB 解碼。
(out/'mask.pfm').write_bytes(b'PF\n63 47\n-1.0\n'+struct.pack('<%df'%(63*47*3), *([1.0]*(63*47*3))))
(out/'swift-report.json').write_text(json.dumps(report,indent=2)+'\n')
sources=['PhotoStyleApp/PhotoStyleProcessor.swift','PhotoStyleApp/PhotoImage.swift','PhotoStyleShared/Sources/PhotoStyleShared/PhotoRepairPatch.swift']
manifest=dict(engineSHA256=hashlib.sha256(args.engine.read_bytes()).hexdigest(), count=len(cases),
    swiftSources={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources},
    files={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.suffix in ['.png','.pfm'] or p.name=='cases.json'})
(out/'reference-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
