#!/usr/bin/env python3
"""比對兩個平台的完整影像指紋及固定像素網格，不把解碼失敗計為通過。"""
import argparse
import json
import math
from pathlib import Path


def metrics(a, b):
    if len(a) != len(b) or not a:
        raise ValueError('像素取樣長度不同')
    errors = sorted(abs(x-y) for x, y in zip(a, b))
    return {'max': errors[-1], 'p99': errors[min(len(errors)-1, int(len(errors)*.99))],
            'rmse': math.sqrt(sum(e*e for e in errors)/len(errors))}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('manifest', 'macos', 'windows', 'output'):
        p.add_argument(name, type=Path)
    args = p.parse_args()
    rows = []
    for sample in json.loads(args.manifest.read_text())['samples']:
        name = sample['id']
        row = {'id': name}
        try:
            mac = json.loads((args.macos/(name+'.json')).read_text(encoding='utf-8-sig'))
            win = json.loads((args.windows/(name+'.json')).read_text(encoding='utf-8-sig'))
            row.update(macosStatus=mac['status'], windowsStatus=win['status'])
            if mac['status'] or win['status']:
                row.update(comparable=False, passed=False, macosError=mac.get('error'), windowsError=win.get('error'))
            else:
                row.update(comparable=True, sameSize=(mac['width'], mac['height']) == (win['width'], win['height']),
                           sameMetadata=mac.get('metadata') == win.get('metadata'),
                           sameLinearFingerprint=mac['linearHashFNV1a'] == win['linearHashFNV1a'],
                           sameDisplayFingerprint=mac['displayHashFNV1a'] == win['displayHashFNV1a'],
                           linear=metrics(mac['linearSamples'], win['linearSamples']),
                           display=metrics(mac['displaySamples'], win['displaySamples']),
                           meanDelta=max(abs(a-b) for a,b in zip(mac['mean'], win['mean'])),
                           meanSquaresDelta=max(abs(a-b) for a,b in zip(mac['meanSquares'], win['meanSquares'])),
                           nonfinite=mac['nonfinite']+win['nonfinite'])
                row['passed'] = (row['sameSize'] and row['sameMetadata'] and row['nonfinite'] == 0
                                 and row['linear']['max'] <= 2/65535 and row['display']['max'] <= 1
                                 and row['meanDelta'] <= 1e-7 and row['meanSquaresDelta'] <= 1e-7)
        except (OSError, ValueError, KeyError) as e:
            row.update(comparable=False, passed=False, error=str(e))
        rows.append(row)
    report = {'samples': len(rows), 'comparable': sum(x['comparable'] for x in rows),
              'passed': sum(x['passed'] for x in rows),
              'threshold': {'linearMax': 2/65535, 'displayMax8bit': 1, 'wholeImageMeanDelta': 1e-7, 'wholeImageMeanSquaresDelta': 1e-7},
              'scope': '完整 RAW 解碼；尺寸、EXIF、全圖 FNV-1a 指紋及固定 64×64 RGB 取樣。指紋不同時的數值容差只保證取樣，不代表每個像素。',
              'results': rows}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k != 'results'}, ensure_ascii=False))
    for row in rows:
        if row['comparable'] and not row['passed']:
            print(row)


if __name__ == '__main__':
    main()
