#!/usr/bin/env python3
"""循序量測原始 CPU CLI 與 Vulkan 反算；總 RSS 是測試工具峰值，不是正式 GPU 流程用量。"""
import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time

from benchmark_film import sha


def execute(command, log):
    with log.open('wb') as stream:
        start = time.perf_counter()
        process = subprocess.Popen([str(s) for s in command], stdout=stream, stderr=stream)
        _, status, usage = os.wait4(process.pid, 0)
        elapsed = time.perf_counter() - start
        process.returncode = os.waitstatus_to_exitcode(status)
    if process.returncode:
        raise RuntimeError(log.read_text()[-4000:])
    return {'wall_seconds': elapsed, 'cpu_seconds': usage.ru_utime + usage.ru_stime,
            'harness_peak_rss_bytes': usage.ru_maxrss * (1 if platform.system() == 'Darwin' else 1024)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--environment', type=Path, required=True)
    args = parser.parse_args()
    build, fixtures = args.build.resolve(), args.fixtures.resolve()
    environment = json.loads(args.environment.read_text())
    if set(environment) != {'VK_DRIVER_FILES', 'VK_LAYER_PATH', 'MVK_CONFIG_FAST_MATH_ENABLED', 'MVK_CONFIG_LOG_LEVEL'}:
        raise ValueError('環境設定欄位不符')
    if environment['MVK_CONFIG_FAST_MATH_ENABLED'] != '0':
        raise ValueError('不可啟用 fast math')
    os.environ.update(environment)
    root = Path(tempfile.mkdtemp(prefix='performance-', dir=build))
    report_path = root / 'report.json'
    manifest = json.loads((fixtures / 'manifest.json').read_text())
    binaries = [build / n for n in ['photo_core_film', 'photo_core_vulkan_smoke', 'photo_core_compare', 'unmix.comp.spv']]
    report = {'schema': 1, 'completed': False, 'platform': platform.platform(),
              'scope': 'unmix 微核心，CPU 單執行緒 double 對 GPU FP32；非整體 GPU 流程',
              'binaries_sha256': {p.name: sha(p) for p in binaries}, 'environment': environment,
              'data_sha256': {p.name: sha(p) for p in (build / 'film-data').iterdir() if p.is_file()},
              'source_manifest_sha256': sha(fixtures / 'manifest.json'), 'cases': []}
    for case in manifest['cases']:
        if not case['id'].endswith('filmPortra400-default'):
            continue
        for field in ('input', 'recipe'):
            path = (fixtures / case[field]).resolve()
            if not path.is_relative_to(fixtures) or sha(path) != case[field + '_sha256']:
                raise ValueError('來源路徑或雜湊不符')
        identifier = case['id']
        print('量測中：' + identifier, flush=True)
        output = root / (identifier + '-cpu.pfm')
        common = ['--input', fixtures / case['input'], '--recipe', fixtures / case['recipe']]
        native = execute([build / 'photo_core_film', *common, '--output', output], root / (identifier + '-cpu.log'))
        hybrid = root / (identifier + '-gpu.pfm')
        harness = execute([build / 'photo_core_vulkan_smoke', *common, '--output', hybrid,
                           '--benchmark-repeats', '3'], root / (identifier + '-gpu.log'))
        gpu = json.loads(Path(str(hybrid) + '.gpu.json').read_text())
        comparison = subprocess.run([str(build / 'photo_core_compare'), str(output), str(hybrid)],
                                    capture_output=True, text=True, check=True)
        metrics = json.loads(comparison.stdout)
        if not (gpu['passed'] and gpu['validation_errors'] == 0 and gpu['cpu_fallback_calls_in_replay'] == 0
                and metrics['passed'] and metrics['max'] < 2):
            raise ValueError('品質或 GPU 執行檢查失敗')
        rows = gpu['benchmark']['runs']
        cpu_ms = statistics.median(r['cpu_ms'] for r in rows)
        gpu_ms = statistics.median(r['gpu']['host_wall_ms'] for r in rows)
        summary = {'cpu_unmix_median_ms': cpu_ms, 'gpu_unmix_host_median_ms': gpu_ms,
                   'gpu_dispatch_median_ms': statistics.median(r['gpu']['dispatch_ms'] for r in rows),
                   'unmix_speedup_with_allocation_and_transfers': cpu_ms / gpu_ms}
        report['cases'].append({'id': identifier, 'fixture': case, 'native_cpu_cli_single_run': native,
            'gpu_harness': harness, 'gpu': gpu, 'native_cpu_vs_hybrid_delta_e00': metrics,
            'summary': summary, 'cpu_output_sha256': sha(output), 'hybrid_output_sha256': sha(hybrid)})
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(identifier, summary, flush=True)
    if len(report['cases']) != 2:
        raise ValueError('需要 280 萬與 2400 萬像素兩組案例')
    for p in binaries:
        if sha(p) != report['binaries_sha256'][p.name]:
            raise ValueError('量測期間執行檔已變更')
    report['completed'] = True
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('完成：' + str(report_path), flush=True)


if __name__ == '__main__':
    main()
