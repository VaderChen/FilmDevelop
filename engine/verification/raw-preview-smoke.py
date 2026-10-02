#!/usr/bin/env python3
"""比對最佳化前後 RAW 預覽／完整輸出的尺寸、像素及冷開耗時。來源僅讀取。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
import re

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--baseline-engine', type=Path, required=True)
parser.add_argument('--engine', type=Path, default=root/'build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine')
parser.add_argument('--full', action='store_true')
parser.add_argument('photos', nargs='+', type=Path)
args = parser.parse_args()
out = Path(tempfile.mkdtemp(prefix='raw-preview-smoke-', dir=root/'build'))
catalog = json.loads((root/'desktop/internal/recipes/catalog.json').read_text())
adjustment = next(s['adjustment'] for s in catalog['styles'] if s['id'] == 'original')
rows = []
for index, photo in enumerate(args.photos):
    photo = photo.resolve()
    digest = hashlib.sha256(photo.read_bytes()).hexdigest()
    results = {}
    for variant, engine in [('before', args.baseline_engine), ('after', args.engine)]:
        output = out/f'{index}-{variant}.png'
        job = {'input': {'path': str(photo), 'rawDecoder': 'software', 'lensCorrection': True},
               'output': {'path': str(output), 'format': 'png', 'bitDepth': 16, 'colorSpace': 'sRGB',
                          'quality': .88, 'maxPixel': 320, 'webPLossless': False, 'tiffCompression': 1},
               'recipe': {'version': 1, 'style': 'original', 'adjustment': adjustment,
                          'repairPatches': [], 'detectSubject': False},
               'computeBackend': 'system', 'preview': True, 'previewMaxPixel': 320,
               'policy': {'highlightProtection': True, 'modernExposure': False, 'hdr': True, 'fullResolution': args.full}}
        start = time.perf_counter()
        memory_log = out/f'{index}-{variant}-memory.log'
        reply = subprocess.run(['/usr/bin/time', '-l', '-o', str(memory_log), str(engine.resolve())], input=json.dumps({'version': 1, 'id': 'raw', 'method': 'render', 'payload': job}),
                               text=True, capture_output=True, timeout=180, check=True)
        elapsed = (time.perf_counter() - start) * 1000
        (out/f'{index}-{variant}.log').write_text(reply.stderr)
        result = json.loads(reply.stdout.splitlines()[-1])
        assert result['kind'] == 'result', (photo.name, variant, result)
        payload = result['payload']
        peak_memory = int(re.search(r'(\d+)\s+maximum resident set size', memory_log.read_text()).group(1))
        results[variant] = {'milliseconds': elapsed, 'rawDecoder': payload['rawDecoder'],
                            'peakResidentBytes': peak_memory,
                            'dimensions': {key: payload[key] for key in ['width', 'height', 'sourceWidth', 'sourceHeight', 'cropWidth', 'cropHeight', 'outputWidth', 'outputHeight']},
                            'timing': payload['timing']}
    pixels = json.loads(subprocess.check_output([str(root/'build/engine-compare-images'), str(out/f'{index}-before.png'), str(out/f'{index}-after.png')]))
    assert results['before']['dimensions'] == results['after']['dimensions'], (photo.name, results)
    assert results['before']['rawDecoder'] == results['after']['rawDecoder'], (photo.name, results)
    assert pixels['maxError'] == 0, (photo.name, pixels)
    assert hashlib.sha256(photo.read_bytes()).hexdigest() == digest
    rows.append({'photo': photo.name, 'sha256': digest, 'results': results, 'pixels': pixels})
    print(json.dumps({'photo': photo.name, 'passed': True, 'milliseconds': {k: round(v['milliseconds'], 1) for k, v in results.items()}}, ensure_ascii=False), flush=True)
(out/'report.json').write_text(json.dumps({'passed': True, 'full': args.full, 'cases': rows}, ensure_ascii=False, indent=2)+'\n')
print(json.dumps({'passed': True, 'report': str(out/'report.json')}, ensure_ascii=False))
