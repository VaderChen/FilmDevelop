#!/usr/bin/env python3
"""下載固定清單中的公開 CC0 RAW；逐檔核對 SHA-256，不鏡像整個樣本庫。"""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--manifest', type=Path, default=Path(__file__).with_name('corpus.json'))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    def download(row):
        if 'url' not in row:
            return
        if row['license'] != 'CC0-1.0' or Path(row['file']).name != row['file']:
            raise ValueError('不接受未授權或不安全的樣本路徑')
        dest = args.output / row['file']
        if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest() == row['sha256']:
            return
        url = urllib.parse.quote(row['url'], safe=':/')
        part = dest.with_suffix(dest.suffix + '.download')
        digest = hashlib.sha256()
        with urllib.request.urlopen(url, timeout=180) as response, part.open('wb') as output:
            size = 0
            while data := response.read(1024 * 1024):
                size += len(data)
                if size > 300 * 1024 * 1024:
                    raise ValueError('樣本超過單檔下載上限')
                digest.update(data)
                output.write(data)
        if digest.hexdigest() != row['sha256']:
            part.unlink()
            raise ValueError('RAW 樣本 SHA-256 不符：' + row['id'])
        part.replace(dest)
        print(row['id'], size, 'SHA-256 OK', flush=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(download, json.loads(args.manifest.read_text())['samples']))


if __name__ == '__main__':
    main()
