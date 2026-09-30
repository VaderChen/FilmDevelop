#!/usr/bin/env python3
"""Vulkan 三模組最終成品閘門：四組既有 Swift 矩陣，逐案驗證 GPU 路徑與 ΔE00。"""
import argparse
import json
from pathlib import Path
import tempfile

from verify_pipeline import digest, verify


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    args = parser.parse_args()
    build = args.build.resolve()
    root = Path(tempfile.mkdtemp(prefix='verification-', dir=build))
    result = {'schema': 1, 'scope': 'vulkan-film-development-scanner', 'passed': True,
              'new_render': True, 'total': 0, 'max_delta_e00': 0,
              'validation_errors': 0, 'validation_warnings': 0, 'groups': [],
              'shader_sha256': digest(build / 'film.comp.spv')}
    stages = set()
    for name, collection in [('film', 'film-fixtures'), ('branches', 'film-branches-fixtures'),
                             ('large', 'film-large-fixtures'), ('odd', 'film-odd-fixtures')]:
        manifest = args.fixtures / collection / 'manifest.json'
        report_path = root / (name + '-report.json')
        verify(manifest, build / 'photo_core_vulkan_film', build / 'photo_core_compare', report_path,
               'film-development-scanner')
        report = json.loads(report_path.read_text())
        if report['manifest_sha256'] != digest(manifest) or report['renderer_sha256'] != digest(build / 'photo_core_vulkan_film'):
            raise ValueError('既有報告來源或執行檔已變更')
        if report['comparator_sha256'] != digest(build / 'photo_core_compare'):
            raise ValueError('比較器已變更')
        if report['renderer_data_sha256'] != {p.name: digest(p) for p in (build / 'film-data').iterdir() if p.is_file()}:
            raise ValueError('底片資料已變更')
        for case in report['cases']:
            if not case['passed']:
                result['passed'] = False
                continue
            target = Path(report['output_directory']) / (case['id'] + '.pfm')
            if digest(target) != case['output_sha256']:
                raise ValueError('既有成品已變更')
            gpu = json.loads(Path(str(target) + '.vk.json').read_text())
            if not (gpu['passed'] and gpu['scope'] == result['scope'] and gpu['gpu_arithmetic'] == 'FP32'
                    and gpu['cpu_pixel_fallbacks'] == 0 and gpu['synchronization_validation']
                    and gpu['validation_errors'] == 0 and gpu['stages'][-1]['stage'] == 'srgb16'):
                raise ValueError('GPU 路徑或 Vulkan 驗證不符')
            result['validation_errors'] += gpu['validation_errors']
            result['validation_warnings'] += gpu['validation_warnings']
            stages.update(s['stage'] for s in gpu['stages'])
            result['max_delta_e00'] = max(result['max_delta_e00'], case['metrics']['max'])
        result['total'] += report['total']
        result['passed'] &= report['passed']
        result['groups'].append({'collection': collection, 'report': str(report_path),
                                 'sha256': digest(report_path), 'passed': report['passed'], 'total': report['total']})
    if digest(build / 'film.comp.spv') != result['shader_sha256']:
        raise ValueError('量測期間 shader 已變更')
    result['gpu_stages'] = sorted(stages)
    source = Path(__file__).resolve().parents[1]
    result['source_sha256'] = {str(p.relative_to(source)): digest(p) for p in (source / 'vulkan').iterdir() if p.is_file()}
    result['note'] = '現有 C++ 三模組範圍；非尚未移植的完整 App 配方。大圖效能案例另與同輪 CPU 成品比較。'
    result['passed'] &= result['max_delta_e00'] < 2
    output = root / 'vulkan-summary.json'
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(f"GPU 最終成品：{'通過' if result['passed'] else '失敗'}，{result['total']} 組，最大 ΔE00={result['max_delta_e00']}；{output}")
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
