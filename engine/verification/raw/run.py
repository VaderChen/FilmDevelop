#!/usr/bin/env python3
"""以正式 C 介面逐檔隔離測試 RAW；失敗會記錄且繼續下一台相機。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('probe', type=Path)
    p.add_argument('manifest', type=Path)
    p.add_argument('samples', type=Path)
    p.add_argument('mapping', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--half', action='store_true')
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    for row in json.loads(args.manifest.read_text())['samples']:
        source = args.samples / row['file']
        dest = args.output / (row['id'] + '.json')
        if not source.exists():
            results.append({'id': row['id'], 'status': -998, 'error': 'source missing'})
            continue
        if hashlib.sha256(source.read_bytes()).hexdigest() != row['sha256']:
            raise ValueError('source hash mismatch: ' + row['id'])
        try:
            run = subprocess.run([str(args.probe.resolve()), str(source.resolve()), str(dest.resolve()),
                                  str(args.mapping.resolve()), '1' if args.half else '0'],
                                 capture_output=True, text=True, timeout=180)
            if run.returncode or not dest.exists():
                raise RuntimeError(f'exit={run.returncode}: {run.stderr[-1000:]}')
            result = json.loads(dest.read_text())
            for key in ('linearSamples', 'displaySamples'):
                result.pop(key, None)
            result['id'] = row['id']
            result['sourceUnchanged'] = hashlib.sha256(source.read_bytes()).hexdigest() == row['sha256']
        except (subprocess.TimeoutExpired, RuntimeError) as e:
            result = {'id': row['id'], 'status': -999, 'error': str(e)}
        results.append(result)
        (args.output / 'report.json').write_text(json.dumps(results, ensure_ascii=False, indent=2)+'\n')
        print(row['id'], result.get('status'), result.get('error', ''), flush=True)


if __name__ == '__main__':
    main()
