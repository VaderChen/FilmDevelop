#!/usr/bin/env python3
"""以標準 D65 原色與傳遞函數建立輸出 ICC，Little CMS 僅用於資料產製。

API 參考：https://www.littlecms.com/LittleCMS2.18%20tutorial.pdf
產物可自由使用；執行期由 Windows WIC 與 C++ 處理，無外部程式相依。
"""
import argparse
import ctypes as c
import hashlib
import json
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'experiments/PhotoCoreCpp/data/color'
parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
source_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
if args.check:
    manifest = json.loads((OUT / 'manifest.json').read_text())
    assert manifest['sourceSHA256'] == source_hash, 'ICC 產製方式已更新'
    for name, digest in manifest['profiles'].items():
        assert hashlib.sha256((OUT / name).read_bytes()).hexdigest() == digest
    print('ICC 色彩描述一致性檢查通過')
    raise SystemExit
prefix = subprocess.check_output(['brew', '--prefix', 'little-cms2'], text=True).strip()
lib = c.CDLL(str(Path(prefix) / 'lib/liblcms2.dylib'))
class xyY(c.Structure):
    _fields_ = [('x', c.c_double), ('y', c.c_double), ('Y', c.c_double)]
class Primaries(c.Structure):
    _fields_ = [('Red', xyY), ('Green', xyY), ('Blue', xyY)]
lib.cmsBuildTabulatedToneCurve16.argtypes = [c.c_void_p, c.c_uint32, c.POINTER(c.c_uint16)]
lib.cmsBuildTabulatedToneCurve16.restype = c.c_void_p
lib.cmsBuildGamma.argtypes = [c.c_void_p, c.c_double]
lib.cmsBuildGamma.restype = c.c_void_p
lib.cmsCreate_sRGBProfile.restype = c.c_void_p
lib.cmsReadTag.argtypes = [c.c_void_p, c.c_uint32]
lib.cmsReadTag.restype = c.c_void_p
lib.cmsDupToneCurve.argtypes = [c.c_void_p]
lib.cmsDupToneCurve.restype = c.c_void_p
lib.cmsCreateRGBProfile.argtypes = [c.POINTER(xyY), c.POINTER(Primaries), c.POINTER(c.c_void_p)]
lib.cmsCreateRGBProfile.restype = c.c_void_p
lib.cmsSetProfileVersion.argtypes = [c.c_void_p, c.c_double]
lib.cmsSaveProfileToFile.argtypes = [c.c_void_p, c.c_char_p]
lib.cmsCloseProfile.argtypes = [c.c_void_p]
lib.cmsFreeToneCurve.argtypes = [c.c_void_p]
lib.cmsMLUalloc.argtypes = [c.c_void_p, c.c_uint32]
lib.cmsMLUalloc.restype = c.c_void_p
lib.cmsMLUsetASCII.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p, c.c_char_p]
lib.cmsWriteTag.argtypes = [c.c_void_p, c.c_uint32, c.c_void_p]
lib.cmsMLUfree.argtypes = [c.c_void_p]
OUT.mkdir(parents=True, exist_ok=True)
profiles = {}
spaces = {}
def dot(a, b):
    return sum(x * y for x, y in zip(a, b))
def cross(a, b):
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
def inverse(m):
    columns = [cross(m[1], m[2]), cross(m[2], m[0]), cross(m[0], m[1])]
    determinant = dot(m[0], columns[0])
    return [[columns[col][row] / determinant for col in range(3)] for row in range(3)]
def to_xyz(primaries):
    columns = [[x / y, 1, (1 - x - y) / y] for x, y in primaries]
    matrix = list(map(list, zip(*columns)))
    white = [.3127 / .329, 1, (1 - .3127 - .329) / .329]
    scales = [dot(row, white) for row in inverse(matrix)]
    return [[matrix[r][col] * scales[col] for col in range(3)] for r in range(3)]
srgb_xyz = to_xyz([(.64, .33), (.30, .60), (.15, .06)])
for name, red, green, blue in [
    ('sRGB', (.64, .33), (.30, .60), (.15, .06)),
    ('displayP3', (.68, .32), (.265, .69), (.15, .06)),
    ('adobeRGB', (.64, .33), (.21, .71), (.15, .06)),
]:
    if name == 'adobeRGB':
        curve = lib.cmsBuildGamma(None, 563 / 256)
    else:
        # sRGB 與 Display P3 使用相同傳遞函數。
        reference = lib.cmsCreate_sRGBProfile()
        curve = lib.cmsDupToneCurve(lib.cmsReadTag(reference, int.from_bytes(b'rTRC', 'big')))
        lib.cmsCloseProfile(reference)
    assert curve
    primaries = Primaries(xyY(*red, 1), xyY(*green, 1), xyY(*blue, 1))
    profile = lib.cmsCreateRGBProfile(c.byref(xyY(.3127, .3290, 1)), c.byref(primaries), (c.c_void_p * 3)(curve, curve, curve))
    assert profile
    lib.cmsSetProfileVersion(profile, 4.3)
    text = lib.cmsMLUalloc(None, 1)
    assert lib.cmsMLUsetASCII(text, b'en', b'US', ('FilmDevelop ' + name).encode())
    assert lib.cmsWriteTag(profile, int.from_bytes(b'desc', 'big'), text)
    lib.cmsMLUfree(text)
    path = OUT / (name + '.icc')
    assert lib.cmsSaveProfileToFile(profile, str(path).encode())
    lib.cmsCloseProfile(profile)
    lib.cmsFreeToneCurve(curve)
    data = bytearray(path.read_bytes())
    data[24:36] = struct.pack('>6H', 2026, 1, 1, 0, 0, 0)
    path.write_bytes(data)
    profiles[path.name] = hashlib.sha256(data).hexdigest()
    target_inverse = inverse(to_xyz([red, green, blue]))
    spaces[name] = {'file': path.name, 'gamma': 563 / 256 if name == 'adobeRGB' else 0,
                    'matrix': [[dot(row, col) for col in zip(*srgb_xyz)] for row in target_inverse]}
(OUT / 'spaces.json').write_text(json.dumps(spaces, indent=2) + '\n')
profiles['spaces.json'] = hashlib.sha256((OUT / 'spaces.json').read_bytes()).hexdigest()
(OUT / 'manifest.json').write_text(json.dumps({'sourceSHA256': source_hash, 'profiles': profiles}, indent=2) + '\n')
print('已產生 sRGB、Display P3、Adobe RGB 色彩描述')
