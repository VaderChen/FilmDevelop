#!/usr/bin/env python3
"""連結正式 RAW 靜態庫，建立可在 macOS 或 Windows x64 執行的解碼探針。"""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['macos-arm64', 'windows-x64'])
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    if args.platform == 'macos-arm64':
        compiler = ['xcrun', 'clang++', '-arch', 'arm64', '-mmacosx-version-min=14.0']
        library = root / 'Vendor/PhotoRAW/macos/lib/libphotoraw.a'
        headers = root / '.cache/photoraw-macos/LibRaw-0.22.2'
    else:
        compiler = ['x86_64-w64-mingw32-g++', '-static', '-static-libgcc', '-static-libstdc++']
        library = root / 'build/windows-cross/raw/libphotoraw.a'
        headers = root / '.cache/photoraw-windows/LibRaw-0.22.2'
    if not library.is_file() or not (headers / 'libraw/libraw.h').is_file():
        raise SystemExit('請先執行此平台的 build-raw 建置腳本')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(compiler + ['-std=c++17', '-O2', '-DLIBRAW_NODLL',
        '-fno-fast-math', '-ffp-contract=off',
        '-I', str(root / 'Vendor/PhotoRAW/src'), '-I', str(headers),
        '-I', str(root / 'experiments/PhotoCoreCpp/third_party'),
        str(Path(__file__).with_name('probe.cpp')), str(library)] +
        (['-lws2_32'] if args.platform == 'windows-x64' else []) +
        ['-o', str(args.output.resolve())], check=True)


if __name__ == '__main__':
    main()
