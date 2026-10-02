#!/usr/bin/env python3
"""沿用 macOS 的 libwebp 來源，交叉編譯 Windows x64 靜態編解碼器與 ICC 封裝。"""
import concurrent.futures
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = root / 'aiTest/ThirdParty/stable-diffusion.cpp/thirdparty/libwebp'
build = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'build/windows-cross/webp'
build.mkdir(parents=True, exist_ok=True)
files = sorted(p for part in ['src/dec', 'src/dsp', 'src/enc', 'src/utils', 'src/mux', 'sharpyuv'] for p in (source / part).glob('*.c') if not p.name.startswith('.'))
headers = sorted(p for p in source.rglob('*.h') if not any(part.startswith('.') for part in p.relative_to(source).parts))
digest = hashlib.sha256(Path(__file__).read_bytes())
digest.update(subprocess.check_output(['x86_64-w64-mingw32-gcc', '--version']))
for path in files + headers:
    digest.update(str(path.relative_to(source)).encode())
    digest.update(path.read_bytes())
stamp = build / 'build.sha256'
archive = build / 'libphotowebp.a'
if stamp.exists() and stamp.read_text().strip() == digest.hexdigest() and archive.exists():
    print('Windows WebP 編解碼器已是最新版本')
    raise SystemExit
def compile(path):
    output = build / (str(path.relative_to(source)).replace('/', '_') + '.o')
    subprocess.run(['x86_64-w64-mingw32-gcc', '-std=c99', '-O3', '-DNDEBUG', '-DWEBP_USE_THREAD=1', '-I', str(source), '-I', str(source / 'src'), '-c', str(path), '-o', str(output)], check=True)
    return output
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as workers:
    objects = list(workers.map(compile, files))
temporary = archive.with_suffix('.a.new')
subprocess.run(['x86_64-w64-mingw32-ar', 'rcs', str(temporary), *map(str, objects)], check=True)
temporary.replace(archive)
(build / 'WebPLicenses').mkdir(exist_ok=True)
for name in ['COPYING', 'PATENTS', 'AUTHORS']:
    shutil.copyfile(source / name, build / 'WebPLicenses' / name)
stamp.write_text(digest.hexdigest() + '\n')
print('Windows x64 WebP 靜態編解碼器完成')
