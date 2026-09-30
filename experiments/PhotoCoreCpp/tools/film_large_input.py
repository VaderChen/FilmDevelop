#!/usr/bin/env python3
"""產生含 HDR、色邊、灰階與高頻條紋的 1024×128 輸入，覆蓋顯影 768 上限分支。"""
from pathlib import Path
import argparse
import math
import struct
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('output',type=Path)
parser.add_argument('--variant',choices=('regular','odd','portrait'),default='regular')
args=parser.parse_args()
w,h=1024,128
rows=[]
for y in range(h):
    row=[]
    for x in range(w):
        base=0.18*2**(-8+12*x/(w-1))
        if y<32:
            rgb=(base,base,base)
        elif y<64:
            rgb=(base*(0.1+0.9*(x%17<8)),base*0.65,base*0.2)
        elif y<96:
            rgb=(base*0.05,base*0.2,base)
        else:
            rgb=(base*(1+0.2*math.sin(x*0.7)),base*(1+0.2*math.sin(y*1.3)),base)
        row.append(rgb)
    rows.append(row)
if args.variant!='regular':
    rows=[row[:-1] for row in rows[:-1]]
if args.variant=='portrait':
    rows=list(zip(*rows))
h,w=len(rows),len(rows[0])
out=bytearray(f"PF\n{w} {h}\n-1.0\n".encode())
for row in reversed(rows):
    for rgb in row:
        out+=struct.pack('<3f',*rgb)
args.output.write_bytes(out)
