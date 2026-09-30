#!/usr/bin/env python3
"""相同線性輸入與配方，循序比較未修改 Swift 原版與 Vulkan 的兩個複雜階段。"""
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


def execute(command, log, environment):
    with log.open('wb') as stream:
        start = time.perf_counter()
        process = subprocess.Popen([str(s) for s in command], stdout=stream, stderr=stream, env=environment)
        _, status, usage = os.wait4(process.pid, 0)
        process.returncode = os.waitstatus_to_exitcode(status)
        elapsed = time.perf_counter() - start
    if process.returncode:
        raise RuntimeError(log.read_text()[-5000:])
    return {'process_wall_seconds': elapsed, 'process_cpu_seconds': usage.ru_utime + usage.ru_stime,
            'harness_peak_rss_bytes': usage.ru_maxrss}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=5)
    args = parser.parse_args()
    if platform.system() != 'Darwin' or args.repeats not in (1, 3, 5, 7, 9, 11, 13, 15):
        parser.error('需要 macOS，次數須為 1–15 的奇數')
    build, fixtures = args.build.resolve(), args.fixtures.resolve()
    root = Path(tempfile.mkdtemp(prefix='swift-vulkan-stages-', dir=build))
    report_path = root / 'report.json'
    environment = os.environ | json.loads((build / 'runtime/environment.json').read_text())
    if environment.get('MVK_CONFIG_FAST_MATH_ENABLED') != '0':
        raise ValueError('必須停用 MoltenVK fast math')
    executables = {'swift': build / 'swift-stage-benchmark', 'vulkan': build / 'photo_core_vulkan_stage_benchmark'}
    executables['vulkan_validated'] = executables['vulkan']
    artifacts = [*set(executables.values()), build / 'photo_core_compare', build / 'film.comp.spv', build / 'swift-stage-build.json']
    report = {'schema': 1, 'completed': False, 'scope': '同步單一階段，含新輸入影像建立／GPU 傳輸及完整 CPU 回讀；不含檔案 I/O',
              'platform': platform.platform(), 'repeats': args.repeats, 'artifacts_sha256': {p.name: sha(p) for p in artifacts},
              'swift_build': json.loads((build / 'swift-stage-build.json').read_text()), 'cases': []}
    original_root = Path(__file__).resolve().parents[3]
    for path, digest in report['swift_build']['source_sha256'].items():
        if sha(original_root / path) != digest:
            raise ValueError('Swift 原始碼與建置時不同')
    if sha(executables['swift']) != report['swift_build']['binary_sha256']:
        raise ValueError('Swift 執行檔不是記錄的 Release 版本')
    manifest = json.loads((fixtures / 'performance/manifest.json').read_text())
    sizes = ['2048x1365', '6000x4000']
    definitions = [
        ('development', fixtures / 'film-fixtures/image-0-filmPortra400-development.json'),
        ('spectral', fixtures / 'performance/filmPortra400-silver.json'),
    ]
    for size in sizes:
        source = fixtures / 'performance' / ('input-' + size + '.pfm')
        expected = next(c['input_sha256'] for c in manifest['cases'] if c['input'] == source.name)
        if sha(source) != expected:
            raise ValueError('輸入 SHA-256 不符')
        for stage, recipe in definitions:
            identifier = size + '-' + stage
            print('比較中：' + identifier, flush=True)
            record = {'id': identifier, 'stage': stage, 'input_sha256': expected, 'recipe_sha256': sha(recipe),
                      'recipe': json.loads(recipe.read_text()), 'results': {}}
            # 每個 backend 暖機一次及重複量測；不同案例交替程序先後。
            order = ['swift', 'vulkan', 'vulkan_validated'] if len(report['cases']) % 2 == 0 else ['vulkan_validated', 'vulkan', 'swift']
            for backend in order:
                output = root / (identifier + '-' + backend + '.pfm')
                sidecar = root / (identifier + '-' + backend + '.json')
                usage = execute([executables[backend], source, recipe, stage, output, sidecar, args.repeats] +
                                (['validation-off'] if backend == 'vulkan' else []),
                                root / (identifier + '-' + backend + '.log'), environment)
                measured = json.loads(sidecar.read_text())
                if not measured['deterministic'] or len(measured['runs_ms']) != args.repeats:
                    raise ValueError('後端結果不完整')
                if backend.startswith('vulkan') and (measured['validation_errors'] or measured['validation_warnings'] or
                                                   measured['cpu_pixel_fallbacks'] or
                                                   measured['validation_enabled'] != (backend == 'vulkan_validated')):
                    raise ValueError('Vulkan 執行或驗證失敗')
                record['results'][backend] = measured | usage | {'output_sha256': sha(output)}
            record['validation_toggle_identical'] = (record['results']['vulkan']['output_sha256'] ==
                                                       record['results']['vulkan_validated']['output_sha256'])
            if not record['validation_toggle_identical']:
                raise ValueError('開關驗證層後成品不同')
            for backend in ('swift', 'vulkan'):
                subprocess.run([str(executables['vulkan']), '--quantize', str(root / (identifier + '-' + backend + '.pfm')),
                                str(root / (identifier + '-' + backend + '-srgb16.pfm'))], check=True)
            record['comparison_domain'] = '該階段整張輸出，兩邊使用同一 sRGB16 量化，再比較所有像素；量化不計入效能時間'
            compared = subprocess.run([str(build / 'photo_core_compare'), str(root / (identifier + '-swift-srgb16.pfm')),
                                       str(root / (identifier + '-vulkan-srgb16.pfm'))], capture_output=True, text=True)
            if compared.returncode not in (0, 1):
                raise RuntimeError(compared.stderr)
            record['stage_output_delta_e00'] = json.loads(compared.stdout)
            swift = statistics.median(record['results']['swift']['runs_ms'])
            vulkan = statistics.median(record['results']['vulkan']['runs_ms'])
            record['vulkan_speedup_vs_swift'] = swift / vulkan
            report['cases'].append(record)
            report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
            print(identifier, f'Swift {swift:.2f} ms / Vulkan {vulkan:.2f} ms / 比值 {swift/vulkan:.3f} / ΔE {record["stage_output_delta_e00"]["max"]:.6f}', flush=True)
    for p in artifacts:
        if sha(p) != report['artifacts_sha256'][p.name]:
            raise ValueError('量測期間執行檔或 shader 改變')
    report['completed'] = True
    report['all_stage_delta_e_passed'] = all(c['stage_output_delta_e00']['passed'] for c in report['cases'])
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('完整報告：' + str(report_path), flush=True)
    if not report['all_stage_delta_e_passed']:
        raise SystemExit('階段輸出色差超過門檻')


if __name__ == '__main__':
    main()
