#!/usr/bin/env python3
"""交叉編譯既有 PhotoRAW 中介層，與 macOS 使用相同 LibRaw 版本及映射資料。"""
import argparse
import concurrent.futures
import gzip
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SHA = '627928088300ecde6ca91ffd202e189203f04ad61ad12f0fe9dc57b9a7a0fb3c'
URL = 'https://codeload.github.com/LibRaw/LibRaw/tar.gz/refs/tags/0.22.2'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    output = parser.parse_args().output.resolve()
    subprocess.run(['python3', str(ROOT / 'scripts/build-raw-dependencies.py'), 'windows-x64'], check=True)
    dependencies = json.loads((ROOT / '.cache/photoraw-dependencies/windows-x64/dependencies.json').read_text())
    cache = ROOT / '.cache/photoraw-windows'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / 'libraw-0.22.2.tar.gz'
    existing = ROOT / '.cache/photoraw-macos/libraw-0.22.2.tar.gz'
    if not archive.exists() and existing.exists():
        shutil.copy2(existing, archive)
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != SHA:
        downloaded = archive.with_suffix('.download')
        urllib.request.urlretrieve(URL, downloaded)
        if hashlib.sha256(downloaded.read_bytes()).hexdigest() != SHA:
            downloaded.unlink()
            raise ValueError('LibRaw 來源雜湊不符')
        downloaded.replace(archive)
    vendor = ROOT / 'Vendor/PhotoRAW'
    compiler = shutil.which('x86_64-w64-mingw32-g++')
    archiver = shutil.which('x86_64-w64-mingw32-ar')
    if not compiler or not archiver:
        raise ValueError('缺少 Windows x64 C++ 工具鏈')
    digest = hashlib.sha256(SHA.encode())
    digest.update(subprocess.check_output([compiler, '--version']))
    digest.update(Path(__file__).read_bytes())
    digest.update((ROOT / 'scripts/build-raw-dependencies.py').read_bytes())
    for library in dependencies['libraries']:
        digest.update(Path(library).read_bytes())
    for path in sorted(p for d in ('src', 'Mapping') for p in (vendor / d).rglob('*') if p.is_file() and not p.name.startswith('.') and not p.name.endswith('.bak')):
        digest.update(str(path.relative_to(vendor)).encode()); digest.update(path.read_bytes())
    stamp = output / 'build.sha256'
    if stamp.exists() and stamp.read_text().strip() == digest.hexdigest() and (output / 'libphotoraw.a').is_file():
        return
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            if not (member.isfile() or member.isdir()) or Path(member.name).is_absolute() or '..' in Path(member.name).parts:
                raise ValueError('LibRaw 封存檔含無效路徑')
        tar.extractall(cache)
    source = cache / 'LibRaw-0.22.2'
    manifest = (source / 'Makefile.am').read_text().split('lib_libraw_a_SOURCES =', 1)[1].split('lib_libraw_r_a_CXXFLAGS', 1)[0]
    sources = list(dict.fromkeys(source / p for p in re.findall(r'src/[A-Za-z0-9_/]+\.cpp', manifest)))
    if len(sources) < 70:
        raise ValueError('LibRaw 編譯清單不完整')
    sources.append(vendor / 'src/PhotoRAW.cpp')
    objects = cache / 'objects'; objects.mkdir(exist_ok=True)
    print('正在交叉編譯 PhotoRAW／LibRaw 0.22.2（Windows x64）…', flush=True)

    def compile_source(path):
        obj = objects / (hashlib.sha256(str(path).encode()).hexdigest() + '.o')
        subprocess.run([compiler, '-std=c++17', '-O2', '-DNDEBUG', '-D_USE_MATH_DEFINES', '-DLIBRAW_NODLL', '-DLIBRAW_NOTHREADS',
                        '-DUSE_ZLIB', '-DUSE_JPEG', '-DUSE_JPEG8', '-DUSE_X3FTOOLS',
                        '-fno-fast-math', '-ffp-contract=off', '-w', '-I', str(source)] +
                       [arg for include in dependencies['includes'] for arg in ('-I', include)] +
                       ['-c', str(path), '-o', str(obj)], check=True)
        return obj

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        compiled = list(executor.map(compile_source, sources))
    output.mkdir(parents=True, exist_ok=True)
    temporary = output / 'libphotoraw.a.new'
    temporary.unlink(missing_ok=True)
    # MRI 不完整支援帶空白的路徑；以工作目錄及固定相對檔名組合靜態庫。
    # ADDLIB 會展開相依庫，不將 .a 當成單一 object 放入 archive。
    combined = objects / 'combined.a'
    combined.unlink(missing_ok=True)
    script = 'CREATE combined.a\n' + ''.join('ADDMOD ' + p.name + '\n' for p in compiled)
    for index, library in enumerate(dependencies['libraries']):
        name = f'dependency-{index}.a'
        shutil.copyfile(library, objects / name)
        script += 'ADDLIB ' + name + '\n'
    subprocess.run([archiver, '-M'], input=script+'SAVE\nEND\n', text=True, cwd=objects, check=True)
    shutil.copyfile(combined, temporary)
    temporary.replace(output / 'libphotoraw.a')
    mapping = output / 'RAWMapping'; mapping.mkdir(exist_ok=True)
    hashes = json.loads((vendor / 'Mapping/sha256.json').read_text())
    for name, expected in hashes.items():
        if name.startswith('._'):
            continue
        data = gzip.decompress((vendor / 'Mapping' / (name + '.gz')).read_bytes())
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError('RAW 色彩映射雜湊不符：' + name)
        (mapping / name).write_bytes(data)
    shutil.copyfile(vendor / 'Mapping/index.tsv', mapping / 'index.tsv')
    licenses = output / 'RAWLicenses'; licenses.mkdir(exist_ok=True)
    for name in ('COPYRIGHT', 'LICENSE.CDDL', 'LICENSE.LGPL'):
        shutil.copyfile(source / name, licenses / name)
    for item in dependencies['licenses']:
        shutil.copyfile(item['source'], licenses / item['name'])
    # X3F 原始碼內含獨立 BSD 授權，必須隨二進位發行。
    x3f = (source / 'src/x3f/x3f_utils_patched.cpp').read_text().split('/*', 1)[1].split('*/', 1)[0]
    (licenses / 'X3F-LICENSE.txt').write_text(x3f.strip()+'\n')
    (licenses / 'DEPENDENCIES.json').write_text(json.dumps(dependencies['sources'], indent=2)+'\n')
    (licenses / 'SOURCE.txt').write_text('LibRaw 0.22.2，依 CDDL 1.0 隨附。來源未修改：\n' + URL + '\nSHA256: ' + SHA + '\n啟用 zlib、JPEG DNG 及 X3F。未啟用 OpenMP、RawSpeed、DNG SDK、GPR SDK 或額外去馬賽克套件。\n')
    stamp.write_text(digest.hexdigest() + '\n')


if __name__ == '__main__':
    main()
