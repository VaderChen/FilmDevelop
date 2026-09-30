#!/usr/bin/env python3
"""從既有色差 fixture 建立可重現的 280 萬／2400 萬像素效能矩陣。"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build', type=Path, help='包含 film-large-input.pfm 與色差 fixture 的建置目錄')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = args.output or args.build / 'performance'
    root.mkdir(parents=True, exist_ok=True)
    source = (args.build / 'film-large-input.pfm').read_bytes()
    header, dimensions, scale, pixels = source.split(b'\n', 3)
    if (header, dimensions, scale, len(pixels)) != (b'PF', b'1024 128', b'-1.0', 1024 * 128 * 12):
        raise RuntimeError('請先使用 film_large_input.py 產生標準合成輸入')
    recipes = [('filmPortra400', 'default', 'film'), ('filmVelvia50', 'development', 'film'),
               ('filmPortra400', 'silver', 'film'), ('filmDelta3200', 'paper-glossy', 'film-branches')]
    cases = []
    for width, height, selected in [(2048, 1365, recipes), (6000, 4000, [recipes[i] for i in (0, 1, 3)])]:
        source_path = root / f'input-{width}x{height}.pfm'
        rows = []
        for y in range(128):
            row = pixels[(127-y)*1024*12:(128-y)*1024*12]
            rows.append(b''.join(row[(x*1024//width)*12:(x*1024//width+1)*12] for x in range(width)))
        with source_path.open('wb') as out:
            out.write(f'PF\n{width} {height}\n-1.0\n'.encode())
            for y in range(height-1, -1, -1):
                out.write(rows[y*128//height])
        source_hash = hashlib.sha256(source_path.read_bytes()).hexdigest()
        for stock, variant, folder in selected:
            recipe_path = root / f'{stock}-{variant}.json'
            shutil.copyfile(args.build / f'{folder}-fixtures/image-0-{stock}-{variant}.json', recipe_path)
            cases.append({'id': f'{width}x{height}-{stock}-{variant}', 'input': source_path.name,
                          'recipe': recipe_path.name, 'input_sha256': source_hash,
                          'recipe_sha256': hashlib.sha256(recipe_path.read_bytes()).hexdigest()})
    (root / 'manifest.json').write_text(json.dumps({'schema': 1, 'cases': cases}, indent=2) + '\n')
    print('已建立 7 組效能案例：', root / 'manifest.json')


if __name__ == '__main__':
    main()
