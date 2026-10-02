#!/usr/bin/env python3
"""擷取或驗證 Swift 框圖相位表；Windows 執行時只讀取數據。"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
from array import array
import struct

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'experiments/PhotoCoreCpp/data/editor'
GENERATOR = 'engine/verification/frame-sampling-reference.swift'
SOURCES = ['PhotoStyleApp/PhotoImage.swift','PhotoStyleApp/PhotoStyleProcessor.swift']
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check',action='store_true')
args=parser.parse_args()
fingerprint={p:sha(ROOT/p) for p in SOURCES}
table=OUT/'frame-sampling.bin'
manifest=OUT/'frame-sampling.json'
if args.check:
    metadata=json.loads(manifest.read_text())
    assert metadata['schema']==3 and metadata['referenceSources']==fingerprint, 'Swift 框圖來源已更新，需重新擷取'
    assert metadata['generatorSHA256']==sha(ROOT/GENERATOR), '框圖擷取器已更新，需重新擷取'
    assert metadata['sha256']==sha(table), '框圖相位表雜湊不符'
else:
    OUT.mkdir(parents=True,exist_ok=True)
    raw=ROOT/'build/windows-frame-data/frame-sampling.f32'
    raw.parent.mkdir(parents=True,exist_ok=True)
    subprocess.run(['swift',str(ROOT/GENERATOR),str(raw)],check=True)
    data=raw.read_bytes();dictionary={};indices=bytearray()
    for i in range(0,len(data),36):
        kernel=data[i:i+36]
        if kernel not in dictionary:dictionary[kernel]=len(dictionary)
        assert len(dictionary)<=256, '取樣核心種類超過檔案格式上限'
        indices.append(dictionary[kernel])
    table.write_bytes(struct.pack('<4sHHHHI',b'FDSF',1,256,9,3,len(dictionary))+b''.join(dictionary)+indices)
    metadata=dict(schema=3,description='Swift AppKit 浮點框圖的通用平移相位核心，與照片、機型、配方無關',
        phaseCount=256,kernelSize=3,boundaryProfiles=9,layout='FDSF v1 header; deduplicated 3x3 Float32 kernels; uint8 indices (phaseY, phaseX, boundaryY, boundaryX)', kernelCount=len(dictionary),
        file=table.name,sha256=sha(table),referenceOS=platform.mac_ver()[0],generator=GENERATOR,
        generatorSHA256=sha(ROOT/GENERATOR),referenceSources=fingerprint)
    manifest.write_text(json.dumps(metadata,ensure_ascii=False,indent=2)+'\n')
data=table.read_bytes()
magic,version,phases,profiles,kernelSize,count=struct.unpack('<4sHHHHI',data[:16])
assert (magic,version,phases,profiles,kernelSize)==(b'FDSF',1,256,9,3) and 0<count<=256
assert len(data)==16+count*36+256*256*9
values=array('f',data[16:16+count*36])
assert all(0<=v<=1 for v in values), '框圖權重非有限值'
assert all(abs(sum(values[i:i+9])-1)<1e-5 for i in range(0,len(values),9)), '框圖權重未保持能量'
assert max(data[16+count*36:])<count, '框圖核心索引不符'
print('框圖相位表與 Swift 來源一致')
