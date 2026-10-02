#!/usr/bin/env python3
"""在隔離資料夾檢查 dist 清理邊界與 Windows 除錯資料精簡。"""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from windows_strip import strip_payload
from release_notes import check_files, load_history

spec = importlib.util.spec_from_file_location('release_package', ROOT / 'scripts/package-release.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

completed = []
check_files(load_history())
completed.append('版本基準、四語翻譯、README 與 CHANGELOG 同步')
with tempfile.TemporaryDirectory(prefix='release-packaging-', dir=ROOT / 'build') as temporary:
    root = Path(temporary)
    outside = root / 'keep.txt'
    outside.write_text('keep')
    folder = root / 'dist'
    folder.mkdir()
    (folder / 'old.zip').write_bytes(b'old')
    (folder / 'link').symlink_to(outside)
    module.clean_dist(root)
    assert not list(folder.iterdir()) and outside.read_text() == 'keep'
    completed.append('舊成品清空，內部連結不穿越專案資料')
    folder.rmdir()
    folder.symlink_to(root, target_is_directory=True)
    try:
        module.clean_dist(root)
        raise AssertionError('不應刪除 dist 指向的專案')
    except ValueError:
        pass
    assert outside.read_text() == 'keep'
    folder.unlink()
    folder.mkdir()
    with module.release_lock(root):
        try:
            with module.release_lock(root):
                raise AssertionError('不應允許同時清理與封裝')
        except ValueError:
            pass
    completed.append('拒絕 dist 連結與同時執行的封裝')
    unsigned = ROOT / 'build/windows-cross/core/libPhotoCompute.dll'
    signed = ROOT / 'build/windows-cross/vc-runtime/bin/vcruntime140.dll'
    before = hashlib.sha256(signed.read_bytes()).hexdigest()
    for source in (unsigned, signed):
        shutil.copy2(source, folder / source.name)
    report = strip_payload(folder)
    assert len(report['files']) == 1 and report['bytesSaved'] > 0
    assert hashlib.sha256((folder / signed.name).read_bytes()).hexdigest() == before
    assert strip_payload(folder)['files'] == []
    completed.append('除錯區段移除、載入內容一致、簽署 Runtime 原樣且重複執行無變化')
print(json.dumps(dict(passed=True, completed=completed), ensure_ascii=False))
