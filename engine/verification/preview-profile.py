#!/usr/bin/env python3
"""量測原生預覽各階段；不修改原照片，所有成品保存在獨立測試目錄。"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import statistics
import subprocess
import tempfile
import time


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('photo', type=Path)
    parser.add_argument('--engine', type=Path, default=root / 'build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine')
    parser.add_argument('--output', type=Path, help='報告與成品目錄；預設為 build 下的新資料夾')
    parser.add_argument('--backends', nargs='+', choices=['system', 'vulkan'], default=['system', 'vulkan'])
    parser.add_argument('--repeats', type=int, default=3, help='每案例次數，第一筆為暖機，不納入中位數')
    args = parser.parse_args()
    if args.repeats < 2:
        parser.error('至少需一次暖機及一次計時')
    photo, worker = args.photo.resolve(strict=True), args.engine.resolve(strict=True)
    output = args.output or Path(tempfile.mkdtemp(prefix='preview-profile-', dir=root / 'build'))
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # 每次執行使用新子目錄，避免覆蓋既有成品或診斷報告。
    run = Path(tempfile.mkdtemp(prefix='run-', dir=output))
    catalog = json.loads((root / 'desktop/internal/recipes/catalog.json').read_text())
    styles = {item['id']: item['adjustment'] for item in catalog['styles']}
    base = {
        'input': {'path': str(photo), 'rawDecoder': 'system', 'lensCorrection': True},
        'output': {'path': '', 'format': 'jpeg', 'bitDepth': 8, 'colorSpace': 'sRGB',
                   'quality': .88, 'maxPixel': 2048, 'webPLossless': False, 'tiffCompression': 1},
        'recipe': {'version': 1, 'style': 'filmEktar100', 'adjustment': styles['filmEktar100'],
                   'repairPatches': [], 'detectSubject': False},
        'computeBackend': 'system', 'preview': True, 'previewMaxPixel': 2048,
        'policy': {'highlightProtection': True, 'modernExposure': False, 'hdr': True, 'fullResolution': False},
    }
    results = []
    cases = [('原片', {}), ('Ektar100', {}), ('曝光', {'exposure': 12}),
             ('HDR', {'hdrAmount': 30}), ('降噪', {'denoise': 40}),
             ('裁切旋轉', {'cropAspectRatio': 'oneOne', 'cropRotation': 8}), ('原尺寸', {})]
    for backend in args.backends:
        log = run / (backend + '-stages.log')
        with log.open('w') as stderr:
            session = subprocess.Popen([str(worker), '--preview-session'], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=stderr, text=True,
                                       env={**os.environ, 'PHOTO_PROFILE_TIMING': '1'})
            try:
                for name, changes in cases:
                    samples, stages = [], []
                    for repeat in range(args.repeats):
                        job = copy.deepcopy(base)
                        job['computeBackend'] = backend
                        if name == '原片':
                            job['recipe']['style'] = 'original'
                            job['recipe']['adjustment'] = copy.deepcopy(styles['original'])
                        job['recipe']['adjustment'].update(changes)
                        job['policy']['fullResolution'] = name == '原尺寸'
                        job['output']['path'] = str(run / f'{backend}-{name}-{repeat}.jpg')
                        request = {'version': 1, 'id': f'{name}-{repeat}', 'method': 'preview', 'payload': job}
                        offset = log.stat().st_size
                        began = time.perf_counter()
                        signal.alarm(180)
                        session.stdin.write(json.dumps(request) + '\n')
                        session.stdin.flush()
                        while True:
                            line = session.stdout.readline()
                            if not line:
                                raise RuntimeError(f'預覽程序提早退出；請檢查 {log}')
                            reply = json.loads(line)
                            if reply['version'] != 1 or reply['id'] != request['id']:
                                raise RuntimeError(f'引擎契約不符：{reply}')
                            if reply['kind'] == 'progress':
                                continue
                            if reply['kind'] != 'result':
                                raise RuntimeError(f'預覽失敗：{reply}')
                            result = reply['payload']
                            break
                        elapsed = (time.perf_counter() - began) * 1000
                        signal.alarm(0)
                        with log.open() as source:
                            source.seek(offset)
                            stages.append([json.loads(line[7:]) for line in source if line.startswith('TIMING ')])
                        samples.append({'milliseconds': elapsed, 'native': result['timing']})
                    names = list(dict.fromkeys(row['stage'] for sample in stages for row in sample))
                    timings = [{'stage': stage, 'medianMilliseconds': statistics.median(
                        sum(row['milliseconds'] for row in sample if row['stage'] == stage) for sample in stages[1:]),
                        'materializations': sum(row['materialized'] for row in stages[-1] if row['stage'] == stage)}
                        for stage in names]
                    results.append({'case': name, 'backend': backend, 'samples': samples,
                                    'medianWarmMilliseconds': statistics.median(row['milliseconds'] for row in samples[1:]),
                                    'stages': sorted(timings, key=lambda row: -row['medianMilliseconds'])})
                    print(f'{backend} {name}: {results[-1]["medianWarmMilliseconds"]:.1f} ms', flush=True)
            finally:
                signal.alarm(0)
                session.stdin.close()
                try:
                    session.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    session.kill()
                    session.wait()
            if session.returncode != 0:
                raise RuntimeError(f'引擎結束狀態異常：{session.returncode}')
    report = {'source': photo.name, 'sourceSHA256': hashlib.sha256(photo.read_bytes()).hexdigest(),
              'engineSHA256': hashlib.sha256(worker.read_bytes()).hexdigest(),
              'warmSamples': args.repeats - 1, 'results': results,
              'scope': '原生引擎預覽；排除 Go 宿主、WebView 與淡入動畫。原尺寸仍以 JPEG 2048 px 傳回。'}
    path = run / 'report.json'
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(path)


if __name__ == '__main__':
    def timeout(_signal, _frame):
        raise TimeoutError('原生預覽超過 180 秒')

    signal.signal(signal.SIGALRM, timeout)
    main()
