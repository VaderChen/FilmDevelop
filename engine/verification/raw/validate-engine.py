#!/usr/bin/env python3
"""對照完整 RAW 探針，抓出正式引擎將低解析縮圖冒充編輯來源的回歸。"""
import argparse
import json
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('report', type=Path)
    p.add_argument('raw_reference', type=Path)
    p.add_argument('output', type=Path)
    args = p.parse_args()
    rows = []
    for record in json.loads(args.report.read_text(encoding='utf-8-sig')):
        row = {'id': record['id'], 'requestedDecoder': record['requestedDecoder']}
        reply = record.get('reply', {})
        if reply.get('kind') != 'result':
            row.update(checked=False, reason='引擎未解碼成功', error=record.get('error', reply.get('error')))
        else:
            reference = json.loads((args.raw_reference/(record['id']+'.json')).read_text())
            if reference['status'] != 0:
                row.update(checked=False, reason='共用解碼器無完整像素參考，不推論原生後端解析度')
            else:
                payload = reply['payload']
                area = payload.get('sourceWidth', 0) * payload.get('sourceHeight', 0)
                ratio = area / (reference['width'] * reference['height'])
                # 容許相機 active crop；此檢查只抓明顯縮圖，不能證明色彩／細節等價。
                row.update(checked=True, sourcePixelRatio=ratio,
                           embeddedPreview=bool(payload.get('embeddedRAWPreview', False)),
                           passed=ratio >= .5 and not payload.get('embeddedRAWPreview', False)
                           and record.get('sourceUnchanged') is True)
        rows.append(row)
    report = {'checked': sum(x['checked'] for x in rows),
              'passed': sum(x.get('passed', False) for x in rows),
              'results': rows,
              'scope': '只驗證已成功解碼的來源不是明顯低解析預覽；未解碼或缺少參考不算通過。'}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k != 'results'}, ensure_ascii=False))
    if any(x['checked'] and not x['passed'] for x in rows):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
