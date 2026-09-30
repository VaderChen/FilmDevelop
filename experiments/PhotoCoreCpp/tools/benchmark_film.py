#!/usr/bin/env python3
"""循序量測真實 CLI 的端到端時間、CPU 時間與單一程序峰值 RSS（macOS／Linux）。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import tempfile
import time


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--renderer', action='append', required=True, help='名稱=執行檔')
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--comparator', type=Path, help='另以最終成品 ΔE00 < 2 驗證不同後端；比較不計入時間')
    args = parser.parse_args()
    if args.repeats < 1 or sys.platform not in ('darwin', 'linux'):
        parser.error('需要 macOS／Linux 及至少一次量測')
    entries = [s.split('=', 1) for s in args.renderer]
    if any(len(entry) != 2 or not entry[0] or not all(c.isalnum() or c in '-_' for c in entry[0]) for entry in entries):
        parser.error('renderer 使用不含路徑字元的名稱=執行檔')
    renderers = {label: Path(path).resolve() for label, path in entries}
    if len(renderers) != len(entries):
        parser.error('renderer 名稱不可重複')
    manifest = json.loads(args.manifest.read_text())
    if not isinstance(manifest.get('cases'), list) or not manifest['cases']:
        parser.error('效能矩陣不可為空')
    base = args.manifest.resolve().parent
    report = {'schema': 1, 'completed': False, 'platform': platform.platform(), 'processor': platform.machine(),
              'metric': 'CLI 含啟動、資料載入、PFM 讀寫及 sRGB16 成品；warm-cache，單程序循序執行',
              'manifest_sha256': sha(args.manifest), 'repeats': args.repeats,
              'renderers': {label: {'path': str(path), 'sha256': sha(path),
                  'data_sha256': {p.name: sha(p) for p in sorted((path.parent / 'film-data').iterdir()) if p.suffix in ('.json', '.f32')}} for label, path in renderers.items()},
              'cases': []}
    if args.comparator:
        args.comparator = args.comparator.resolve()
        report['comparator_sha256'] = sha(args.comparator)
    for label, path in renderers.items():
        report['renderers'][label]['shader_sha256'] = {p.name: sha(p) for p in path.parent.glob('*.spv')}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='film-benchmark-', dir=args.report.parent) as directory:
        tmp = Path(directory)
        for case in manifest['cases']:
            source, recipe = base / case['input'], base / case['recipe']
            for key, path in [('input', source), ('recipe', recipe)]:
                if sha(path) != case[key + '_sha256']:
                    raise RuntimeError('測試資料已變更：' + str(path))
            record = {'id': case['id'], 'results': {}}
            for label in renderers:
                record['results'][label] = {'runs': []}
            labels = list(renderers)
            # 每個 renderer 暖機一次；測量輪次反轉順序以減少固定先後偏差。
            for trial in range(-1, args.repeats):
                for label in (labels if trial % 2 == 0 else list(reversed(labels))):
                    output = tmp / (label + '.pfm')
                    with (tmp / 'process.log').open('wb') as log:
                        start = time.perf_counter()
                        process = subprocess.Popen([str(renderers[label]), '--input', str(source),
                            '--recipe', str(recipe), '--output', str(output)], stdout=log, stderr=log)
                        _, status, usage = os.wait4(process.pid, 0)
                        elapsed = time.perf_counter() - start
                        process.returncode = os.waitstatus_to_exitcode(status)
                    if process.returncode:
                        raise RuntimeError((tmp / 'process.log').read_text())
                    digest = sha(output)
                    previous = record['results'][label].setdefault('output_sha256', digest)
                    if digest != previous:
                        raise RuntimeError('同一參數的輸出不確定：' + case['id'])
                    if trial >= 0:
                        record['results'][label]['runs'].append({'wall_seconds': elapsed,
                            'cpu_seconds': usage.ru_utime + usage.ru_stime,
                            'peak_rss_bytes': usage.ru_maxrss * (1 if sys.platform == 'darwin' else 1024)})
                    gpu_report = Path(str(output) + '.vk.json')
                    if gpu_report.exists():
                        gpu = json.loads(gpu_report.read_text())
                        if not (gpu['passed'] and gpu['cpu_pixel_fallbacks'] == 0
                                and gpu['validation_errors'] == 0 and gpu['synchronization_validation']):
                            raise RuntimeError('GPU 路徑或 Vulkan 驗證未通過')
                        if trial >= 0:
                            record['results'][label]['runs'][-1]['vulkan'] = gpu
            for label, result in record['results'].items():
                for metric in ('wall_seconds', 'cpu_seconds', 'peak_rss_bytes'):
                    result['median_' + metric] = statistics.median(run[metric] for run in result['runs'])
                result['max_peak_rss_bytes'] = max(run['peak_rss_bytes'] for run in result['runs'])
            record['identical_output'] = len({r['output_sha256'] for r in record['results'].values()}) == 1
            if args.comparator:
                record['delta_e00'] = {}
                for label in labels[1:]:
                    measured = subprocess.run([str(args.comparator), str(tmp / (labels[0] + '.pfm')),
                        str(tmp / (label + '.pfm'))], capture_output=True, text=True, check=True)
                    metrics = json.loads(measured.stdout)
                    if not metrics['passed'] or metrics['max'] >= 2:
                        raise RuntimeError('不同後端最終成品 ΔE00 未通過')
                    record['delta_e00'][labels[0] + '_vs_' + label] = metrics
            report['cases'].append(record)
            args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
            print(case['id'], {k: round(v['median_wall_seconds'], 3) for k, v in record['results'].items()},
                  '輸出一致=' + str(record['identical_output']), flush=True)

    for label, path in renderers.items():
        if sha(path) != report['renderers'][label]['sha256']:
            raise RuntimeError('量測期間執行檔已變更：' + label)
        if {p.name: sha(p) for p in path.parent.glob('*.spv')} != report['renderers'][label]['shader_sha256']:
            raise RuntimeError('量測期間 shader 已變更：' + label)
    report['completed'] = True
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
