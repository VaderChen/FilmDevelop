#!/usr/bin/env python3
"""只封裝 Core ML 執行模型，避免將同一組來源權重再放進 App。"""
import hashlib
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source, destination = map(Path, sys.argv[1:])
cache = root / 'build/coreml-models'
cache.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='models-', dir=cache) as temporary:
    staged = Path(temporary)
    packages = [p for p in source.iterdir() if p.suffix in ('.mlpackage', '.mlmodel')]
    names = {p.stem for p in packages}
    assert len(names) == len(packages), '模型名稱重複'
    for package in packages:
        digest = hashlib.sha256(platform.mac_ver()[0].encode())
        inputs = sorted(p for p in package.rglob('*') if p.is_file()) if package.is_dir() else [package]
        for path in inputs:
            digest.update(str(path.relative_to(source)).encode())
            digest.update(path.read_bytes())
        compiled = cache / digest.hexdigest() / (package.stem + '.mlmodelc')
        if not compiled.is_dir():
            with tempfile.TemporaryDirectory(prefix='compile-', dir=cache) as work:
                subprocess.run(['xcrun', 'coremlcompiler', 'compile', str(package), work], check=True)
                result = Path(work) / compiled.name
                assert result.is_dir(), '未產生編譯模型'
                compiled.parent.mkdir(exist_ok=True)
                shutil.move(str(result), compiled)
        shutil.copytree(compiled, staged / compiled.name)
    for path in source.iterdir():
        if path.name.startswith('.') or '.bak' in path.name or path.suffix in ('.mlpackage', '.mlmodel'):
            continue
        if path.suffix == '.mlmodelc' and path.stem in names:
            continue
        if path.is_dir():
            shutil.copytree(path, staged / path.name)
        else:
            shutil.copy2(path, staged / path.name)
    destination.mkdir(parents=True, exist_ok=True)
    subprocess.run(['rsync', '-a', '--delete', str(staged) + '/', str(destination) + '/'], check=True)
