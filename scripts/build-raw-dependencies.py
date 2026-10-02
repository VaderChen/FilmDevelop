#!/usr/bin/env python3
"""為兩個 RAW 後端建立相同版本的 zlib 與 JPEG 靜態相依庫。"""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    'zlib': ('1.3.2', 'https://zlib.net/fossils/zlib-1.3.2.tar.gz',
             'bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16'),
    'libjpeg-turbo': ('3.1.4.1', 'https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.1.4.1/libjpeg-turbo-3.1.4.1.tar.gz',
                     'ecae8008e2cc9ade2f2c1bb9d5e6d4fb73e7c433866a056bd82980741571a022'),
}


def build(platform):
    root = ROOT / '.cache/photoraw-dependencies'
    root.mkdir(parents=True, exist_ok=True)
    with (root / 'build.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return build_locked(platform, root)


def build_locked(platform, root):
    output = root / platform
    output.mkdir(exist_ok=True)
    result = {'includes': [], 'libraries': [], 'licenses': [], 'sources': []}
    compiler_command = ['x86_64-w64-mingw32-gcc', '--version'] if platform == 'windows-x64' else ['xcrun', 'clang', '--version']
    compiler_identity = subprocess.check_output(compiler_command)
    for name, (version, url, sha) in SOURCES.items():
        archive = root / f'{name}-{version}.tar.gz'
        if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != sha:
            part = archive.with_suffix('.download')
            urllib.request.urlretrieve(url, part)
            if hashlib.sha256(part.read_bytes()).hexdigest() != sha:
                part.unlink()
                raise ValueError(name + ' 來源 SHA-256 不符')
            part.replace(archive)
        source = root / f'{name}-{version}'
        if not source.exists():
            with tarfile.open(archive) as tar:
                for item in tar.getmembers():
                    if not (item.isfile() or item.isdir()) or Path(item.name).is_absolute() or '..' in Path(item.name).parts:
                        raise ValueError('不安全的相依庫封存檔')
                tar.extractall(root)
        directory = output / name
        flags = ['-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=OFF',
                 '-DCMAKE_INSTALL_PREFIX=' + str(directory / 'install')]
        if platform == 'windows-x64':
            flags += ['-DCMAKE_SYSTEM_NAME=Windows', '-DCMAKE_SYSTEM_PROCESSOR=AMD64',
                      '-DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc',
                      '-DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres']
        else:
            flags += ['-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0']
        if name == 'zlib':
            flags += ['-DZLIB_BUILD_TESTING=OFF', '-DZLIB_BUILD_SHARED=OFF', '-DZLIB_BUILD_STATIC=ON']
            target = 'zlibstatic'
        else:
            # 固定整數 DCT，避免平台 SIMD 選擇影響 RAW 一致性驗證。
            flags += ['-DENABLE_SHARED=OFF', '-DENABLE_STATIC=ON', '-DWITH_TURBOJPEG=OFF',
                      '-DWITH_TOOLS=OFF', '-DWITH_TESTS=OFF', '-DWITH_SIMD=OFF']
            target = 'jpeg-static'
        stamp = directory / 'source.sha256'
        fingerprint = hashlib.sha256(compiler_identity + (sha + json.dumps(flags) + hashlib.sha256(Path(__file__).read_bytes()).hexdigest()).encode()).hexdigest()
        if not stamp.exists() or stamp.read_text().strip() != fingerprint or not list(directory.glob('*.a')):
            subprocess.run(['cmake', '-S', str(source), '-B', str(directory), '-G', 'Ninja'] + flags, check=True)
            subprocess.run(['cmake', '--build', str(directory), '--target', target, '-j4'], check=True)
            stamp.write_text(fingerprint+'\n')
        libraries = list(directory.glob('*.a'))
        expected = [p for p in libraries if ('jpeg' in p.name if name == 'libjpeg-turbo' else 'z' in p.name)]
        if len(expected) != 1:
            raise ValueError('找不到唯一的靜態庫：' + str(directory))
        result['includes'] += [str(source), str(directory)]
        if name == 'libjpeg-turbo':
            result['includes'].append(str(source / 'src'))
        result['libraries'] += [str(expected[0])]
        for license_name in (('LICENSE',) if name == 'zlib' else ('LICENSE.md', 'README.ijg')):
            result['licenses'].append({'source': str(source / license_name), 'name': name + '-' + license_name})
        result['sources'].append({'name': name, 'version': version, 'url': url, 'sha256': sha})
    (output / 'dependencies.json').write_text(json.dumps(result, indent=2)+'\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['macos-arm64', 'windows-x64'])
    build(parser.parse_args().platform)
