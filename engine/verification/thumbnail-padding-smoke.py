#!/usr/bin/env python3
"""以含 4:3 補邊 JPEG 的 3:2 Bayer DNG，驗證原生縮圖→Go→真實 Wails 交接。"""
import base64
import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile

from PIL import Image

root = Path(__file__).resolve().parents[2]
out = Path(tempfile.mkdtemp(prefix='thumbnail-padding-', dir=root/'build'))
worker = root/'build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine'
pack = lambda fmt, *values: struct.pack('<'+fmt, *values)


def fixture(path, orientation):
    width, height = 384, 256
    thumbnail = Image.new('RGB', (256, 192))
    for y in range(171):
        for x in range(256):
            thumbnail.putpixel((x, y+10), (60+x//4, 40+y//2, 80))
    encoded = io.BytesIO()
    thumbnail.save(encoded, format='JPEG', quality=90)
    jpeg = encoded.getvalue()
    tags = []
    def tag(number, kind, count, data): tags.append((number, kind, count, data))
    for number, value in [(256,width), (257,height), (273,0), (278,height), (279,width*height*2), (50717,65535)]:
        tag(number,4,1,pack('I',value))
    for number, value in [(258,16),(259,1),(262,32803),(274,orientation),(277,1),(284,1),(50778,21)]:
        tag(number,3,1,pack('H',value))
    tag(33421,3,2,pack('HH',2,2)); tag(33422,1,4,bytes([0,1,1,2]))
    tag(50706,1,4,bytes([1,4,0,0])); tag(50707,1,4,bytes([1,1,0,0]))
    model = b'Thumbnail Geometry Camera\0'; tag(50708,2,len(model),model)
    tag(50720,4,2,pack('II',width,height))
    tag(50721,10,9,b''.join(pack('ii',int(i%4==0),1) for i in range(9)))
    tag(50728,5,3,pack('IIIIII',1,1,1,1,1,1))
    tags.sort(); base = 8+2+12*len(tags)+4
    extra, entries = bytearray(), []
    for number,kind,count,data in tags:
        if len(data)>4:
            value=pack('I',base+len(extra)); extra.extend(data)
            if len(extra)%2: extra.append(0)
        else: value=data.ljust(4,b'\0')
        entries.append((number,kind,count,value))
    preview_offset=base+len(extra)
    jpeg_offset=preview_offset+2+6*12+4
    pixels_offset=jpeg_offset+len(jpeg)
    header=b'II'+pack('HIH',42,8,len(tags))+b''.join(pack('HHI',n,k,c)+(pack('I',pixels_offset) if n==273 else v) for n,k,c,v in entries)+pack('I',preview_offset)
    preview=pack('H',6)+b''.join(pack('HHII',n,4,1,v) for n,v in [(254,1),(256,256),(257,192),(274,orientation),(513,jpeg_offset),(514,len(jpeg))])+pack('I',0)
    pixels=b''.join(pack('H',8000+(x+y)*60) for y in range(height) for x in range(width))
    path.write_bytes(header+extra+preview+jpeg+pixels)


sources=[out/'landscape.dng',out/'portrait.dng']
for source, orientation in zip(sources,[1,6]):
    fixture(source,orientation)
    request={'version':1,'id':'padding','method':'thumbnail','payload':{'path':str(source),'maxPixel':256}}
    response=subprocess.run([str(worker)],input=json.dumps(request),text=True,capture_output=True,check=True,timeout=30)
    result=json.loads(response.stdout.splitlines()[-1])
    assert result['kind']=='result',result
    raw=Image.open(io.BytesIO(base64.b64decode(result['payload']['imageData'])))
    assert raw.size==((256,192) if orientation==1 else (192,256)),raw.size
    raw.save(out/(source.stem+'-native.png'))

report=out/'report.json'
subprocess.run(['python3',str(root/'engine/verification/preview-navigation-smoke.py'),*map(str,sources),'--report',str(report)],check=True,stdout=(out/'navigation.log').open('w'))
result=json.loads(report.read_text())
sizes={(sample['naturalWidth'],sample['naturalHeight']) for case in result['results'] for sample in case['geometry'] if sample['loading']}
assert sizes=={(256,171),(171,256)},sizes
result['paddingVerification']={'passed':True,'nativeSizes':[[256,192],[192,256]],'displaySizes':sorted(map(list,sizes)),
    'scope':'原生引擎保留相機內嵌補邊；Go 依 RAW 尺寸移除補邊，橫直幅初次載入及暖快取的 Wails 顯示都充分適應視窗。'}
report.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'passed':True,'report':str(report)},ensure_ascii=False))
