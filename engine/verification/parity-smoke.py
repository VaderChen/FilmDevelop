#!/usr/bin/env python3
"""在隔離資料目錄驗證 JPEG、單張顯影、複選進度及已恢復的操作流程。"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--unsupported-rename', action='store_true')
parser.add_argument('--second', action='store_true')
args = parser.parse_args()
out = Path(tempfile.mkdtemp(prefix='parity-smoke-', dir=root / 'build'))
source = Path(json.loads((root / 'build/engine-smoke-latest.json').read_text())['report']).parent / '來源照片.bmp'
directory = out / '照片'; directory.mkdir()
first = directory / 'photo2.bmp'; first.write_bytes(source.read_bytes())
(directory / 'photo10.bmp').write_bytes(source.read_bytes())
(directory / 'zz-invalid.jpg').write_bytes(b'broken image')
binary = out / 'FilmDevelopParitySmoke'
subprocess.run(['python3', str(root / 'scripts/prepare-desktop.py')], check=True)
build = ['go', '-C', str(root / 'desktop'), 'build', '-race', '-tags', 'desktop,production,enginesmoke', '-o', str(binary)]
if args.unsupported_rename:
    original = root / 'desktop/internal/engine/publish_darwin.go'
    replacement = out / 'publish_darwin.go'
    replacement.write_text(original.read_text().replace('publishDarwin(source, target, unix.RenamexNp)', 'publishDarwin(source, target, func(string, string, uint32) error { return unix.ENOTSUP })'))
    overlay = out / 'overlay.json'; overlay.write_text(json.dumps({'Replace': {str(original): str(replacement)}}))
    build += ['-overlay', str(overlay)]
subprocess.run(build + ['./cmd/filmdevelop-desktop'], check=True)
env = dict(os.environ, FILMDEVELOP_ENGINE=str(root / 'build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine'),
           FILMDEVELOP_DATA_DIR=str(out / 'data'), FILMDEVELOP_SMOKE_REPORT=str(out / 'report.json'),
           FILMDEVELOP_SMOKE_INPUT=str(first), FILMDEVELOP_SMOKE_OUTPUT=str(out / 'export.jpg'),
           FILMDEVELOP_SMOKE_DIRECTORY=str(directory), FILMDEVELOP_SMOKE_PARITY='2' if args.second else '1')
with (out / 'stdout.log').open('w') as stdout, (out / 'stderr.log').open('w') as stderr:
    subprocess.run([str(binary)], env=env, stdout=stdout, stderr=stderr, timeout=180, check=True)
report = json.loads((out / 'report.json').read_text())
assert report['passed'], report
if not args.second:
    assert (out / 'export.jpg').read_bytes().startswith(b'\xff\xd8')
    assert len(list(out.glob('照片 *.jpg'))) == 2
assert not list(out.glob('.filmdevelop-*'))
assert 'DATA RACE' not in (out / 'stderr.log').read_text()
report['unsupportedRenameSimulated'] = args.unsupported_rename
(out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
print(json.dumps({'passed': True, 'checks': len(report['completed']), 'report': str(out / 'report.json')}, ensure_ascii=False))
