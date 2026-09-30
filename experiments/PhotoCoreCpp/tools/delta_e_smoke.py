#!/usr/bin/env python3
"""驗證整張成品判定與錯誤路徑；不是引擎色差驗收。"""
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

exe = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="photocore-delta-e-") as tmp:
    root = Path(tmp)
    def pfm(name, pixels, width=None):
        path = root / name
        path.write_bytes(f"PF\n{width or len(pixels)} {len(pixels)//(width or len(pixels))}\n-1.0\n".encode()
                         + b"".join(struct.pack("<3f", *p) for p in pixels))
        return path
    def compare(a, b, code):
        p = subprocess.run([exe, str(a), str(b)], capture_output=True, text=True)
        if p.returncode != code:
            raise RuntimeError((p.returncode, p.stdout, p.stderr))
        return json.loads(p.stdout) if code in (0, 1) else None
    source = pfm("原片.pfm", [(0.18,)*3]*100)
    same = compare(source, source, 0)
    if same["max"] != 0 or same["pixels"] != 100:
        raise RuntimeError("相同成品比較失敗")
    small = pfm("微差.pfm", [(0.181,)*3]*100)
    if not 0 < compare(source, small, 0)["max"] < 2:
        raise RuntimeError("小於門檻比較失敗")
    one = pfm("單點大誤差.pfm", [(0.18,)*3]*99 + [(1,)*3])
    result = compare(source, one, 1)
    if not (result["mean"] < 2 and result["max"] > 2 and result["pixels_at_or_above_2"] == 1
            and result["worst_x"] == 99):
        raise RuntimeError("平均值掩蓋單點誤差")
    compare(source, pfm("大小不同.pfm", [(0.18,)*3]), 2)
    compare(source, pfm("HDR中間值.pfm", [(2,)*3]*100), 2)
    compare(source, pfm("NaN.pfm", [(float('nan'),)*3]*100), 2)
    # 位置錯置不能經對齊／排序後視為同圖。
    compare(pfm("左右.pfm", [(0,)*3, (1,)*3]), pfm("右左.pfm", [(1,)*3, (0,)*3]), 1)
print("ΔE00 整張成品比較 Smoke 通過（不代表 C++ 全流程已達標）")
