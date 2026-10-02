#!/usr/bin/env python3
"""以產品 JSONL 契約檢查 RAW 路由、方向尺寸及可用預覽，不把縮圖當解碼。"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import time


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('engine', 'manifest', 'samples', 'recipe', 'output'):
        p.add_argument(name, type=Path)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    adjustment = json.loads(args.recipe.read_text())
    results = []
    for row in json.loads(args.manifest.read_text())['samples']:
        source = (args.samples / row['file']).resolve()
        for decoder in ('system', 'software'):
            name = row['id'] + '-' + decoder
            output = (args.output / (name+'.png')).resolve()
            if output.exists():
                raise ValueError('請指定全新的結果目錄：' + str(output))
            job = {'input': {'path': str(source), 'rawDecoder': decoder, 'lensCorrection': False},
                   'output': {'path': str(output), 'format': 'png', 'bitDepth': 16, 'colorSpace': 'sRGB',
                              'quality': .95, 'maxPixel': 512, 'webPLossless': False, 'tiffCompression': 1},
                   'recipe': {'version': 1, 'style': 'original', 'adjustment': adjustment,
                              'repairPatches': [], 'detectSubject': False},
                   'computeBackend': 'system', 'preview': True, 'previewMaxPixel': 512,
                   'policy': {'highlightProtection': True, 'modernExposure': False, 'hdr': True, 'fullResolution': False}}
            request = {'version': 1, 'id': name, 'method': 'render', 'payload': job}
            start = time.monotonic()
            result = {'id': row['id'], 'requestedDecoder': decoder}
            try:
                run = subprocess.run([str(args.engine.resolve())], input=json.dumps(request)+'\n',
                                     text=True, capture_output=True, timeout=180)
                replies = [json.loads(line) for line in run.stdout.splitlines() if line.startswith('{')]
                final = next(r for r in reversed(replies) if r.get('kind') != 'progress')
                result['reply'] = final
                result['exitCode'] = run.returncode
                if output.exists():
                    data = output.read_bytes()
                    if data[:8] != b'\x89PNG\r\n\x1a\n':
                        raise ValueError('PNG signature mismatch')
                    result['pngSize'] = struct.unpack('>II', data[16:24])
                    result['outputBytes'] = len(data)
                    result['outputSHA256'] = hashlib.sha256(data).hexdigest()
                result['sourceUnchanged'] = hashlib.sha256(source.read_bytes()).hexdigest() == row['sha256']
            except Exception as e:
                result['error'] = str(e)
            result['seconds'] = time.monotonic()-start
            results.append(result)
            (args.output / 'report.json').write_text(json.dumps(results, ensure_ascii=False, indent=2)+'\n')
            print(name, result.get('reply', {}).get('kind'), result.get('error',''), flush=True)


if __name__ == '__main__':
    main()
