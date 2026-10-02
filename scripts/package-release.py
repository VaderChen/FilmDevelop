#!/usr/bin/env python3
"""完整發布封裝：先清空專案 dist 一次，再建置 Mac DMG 與 Windows ZIP。"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from release_notes import check_files, load_history, release_body
from windows_resources import ROOT, project_version


def clean_dist(root):
    root = Path(root).resolve(strict=True)
    folder = root / 'dist'
    if folder.is_symlink() or folder.exists() and not folder.is_dir() or os.path.ismount(folder):
        raise ValueError('dist 必須是專案內的一般目錄，不可為連結或掛載點')
    if folder.exists():
        # 不跟隨目錄內的符號連結；不允許穿越其他掛載點。
        for base, directories, _ in os.walk(folder, followlinks=False):
            if any(os.path.ismount(Path(base) / name) for name in directories):
                raise ValueError('dist 內含掛載點，停止清理')
        shutil.rmtree(folder)
    folder.mkdir()
    return folder


@contextmanager
def release_lock(root):
    (root / 'build').mkdir(exist_ok=True)
    with (root / 'build/release-package.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('另一輪發布封裝正在執行，不能清空 dist') from None
        yield


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity', required=True, help='本機 Developer ID Application 身分')
    parser.add_argument('--notary-profile', required=True, help='本機 Keychain 公證設定')
    args = parser.parse_args()
    if args.identity == '-':
        parser.error('正式發布需要 Developer ID 簽章')
    with release_lock(ROOT):
        data = load_history()
        check_files(data)
        # 清理前確認憑證可用；不把授權資料、建置設定或照片放入 dist。
        subprocess.run(['xcrun', 'notarytool', 'history', '--keychain-profile', args.notary_profile,
                        '--output-format', 'json'], stdout=subprocess.DEVNULL, check=True)
        destination = clean_dist(ROOT)
        print('已清空專案 dist；開始本輪 Mac／Windows 封裝。', flush=True)
        def run(*command):
            subprocess.run(command, cwd=ROOT, check=True)
        run('bash', 'scripts/build-desktop-macos.sh')
        run(sys.executable, 'scripts/package-macos.py', '--identity', args.identity,
            '--notary-profile', args.notary_profile)
        run(sys.executable, 'scripts/package-windows.py')
        version = project_version()
        tag = f"v{version['version']}-build-{version['build']}"
        v, b = version['version'], version['build']
        # 只列出本輪確切名稱，不使用可能把診斷紀錄一併上傳的萬用字元。
        files = [destination / 'macos-arm64' / f'FilmDevelop-{v}-build{b}-macos-arm64.dmg',
                 destination / 'macos-arm64' / f'FilmYourPhoto-{v}-build-{b}-arm64.dmg',
                 destination / 'windows-x64' / f'FilmDevelop-{v}-build{b}-windows-x64-portable.zip']
        entries = []
        for path in files:
            checksum = hashlib.sha256()
            with path.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    checksum.update(block)
            entries.append(dict(path=path.relative_to(destination).as_posix(), size=path.stat().st_size,
                                sha256=checksum.hexdigest()))
        (destination / 'SHA256SUMS.txt').write_text(''.join(f"{e['sha256']}  {Path(e['path']).name}\n" for e in entries))
        (destination / 'release-notes.md').write_text(release_body(data, tag))
        (destination / 'artifacts.json').write_text(json.dumps(dict(tag=tag, previousTag=data['releases'][0]['previousTag'],
                                                                   cleanedBeforeBuild=True, artifacts=entries), indent=2) + '\n')
        print('本輪成品及四語說明已完成；需通過實機驗證後再發布 GitHub Release。')


if __name__ == '__main__':
    main()
