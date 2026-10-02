#!/usr/bin/env python3
"""唯讀本機 Swift／Go 資料，以隔離副本測試分類、分級遷移及兩次桌面啟動。"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
out = Path(tempfile.mkdtemp(prefix='organization-local-smoke-', dir=root/'build'))
support = Path.home()/'Library/Application Support'
swift_root = support/'PhotoStyleApp'
go_root = support/'FilmDevelop-GoDevelopment'
source = swift_root/'PhotoOrganization.json'
go_source = go_root/'state/organization.json'

def digest(path):
    with path.open('rb') as stream:
        hash_value = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            hash_value.update(chunk)
        return hash_value.hexdigest()

library = json.loads(source.read_text())
browser = json.loads((go_root/'state/browser.json').read_text())
directories = set(browser.get('recent', []) + [browser.get('directory', '')])
matched = {}
for directory in sorted(directories):
    if not directory or not Path(directory).is_dir():
        continue
    for path in Path(directory).iterdir():
        identity = hashlib.sha256(str(path.resolve()).encode()).hexdigest()
        if path.is_file() and identity in library['photos']:
            matched[identity] = path.resolve()
assert matched, '本機最近目錄找不到 Swift 已分級／分類照片，未宣稱相容測試通過'
paths = sorted(matched.values())
assert len({p.parent for p in paths}) == 1, '此 UI Smoke 需要同一目錄的本機樣本'
protected = [source, go_source, go_root/'state/browser.json'] + paths
before = {str(p): digest(p) for p in protected}

oracle = out/'SwiftOrganizationReference'
subprocess.run(['xcrun', 'swiftc', str(root/'PhotoStyleApp/PhotoOrganizationStore.swift'),
                str(root/'engine/verification/organization-reference.swift'), '-o', str(oracle)], check=True)
def swift_read(path):
    return json.loads(subprocess.check_output([str(oracle), str(path), *map(str, paths)]))

fixture = swift_read(source)
for photo in fixture['photos']:
    assert {'rating': photo['rating'], 'tags': photo['tags']} == library['photos'][photo['id']]
(out/'swift-reference.json').write_text(json.dumps(fixture, ensure_ascii=False, indent=2)+'\n')
legacy = out/'legacy'
legacy.mkdir()
shutil.copy2(source, legacy/'PhotoOrganization.json')
if (swift_root/'PhotoEdits').is_dir():
    shutil.copytree(swift_root/'PhotoEdits', legacy/'PhotoEdits')
data = out/'data'
(data/'state').mkdir(parents=True)
shutil.copy2(go_source, data/'state/organization.json')
(data/'state/browser.json').write_text(json.dumps({'version': 1, 'directory': str(paths[0].parent), 'photo': str(paths[0]), 'recent': [str(paths[0].parent)]}))
# 保留使用者對模型與加速的既有選擇；測試隔離服務和自動更新。
preferences = json.loads((go_root/'state/preferences.json').read_text())
preferences['mcpEnabled'] = False
(data/'state/preferences.json').write_text(json.dumps(preferences))
binary = out/'FilmDevelopOrganizationSmoke'
subprocess.run(['python3', str(root/'scripts/prepare-desktop.py')], check=True)
subprocess.run(['go', '-C', str(root/'desktop'), 'build', '-race', '-tags', 'desktop,production,enginesmoke', '-o', str(binary), './cmd/filmdevelop-desktop'], check=True)
reports = []
try:
    for stage in ['import', 'reopen']:
        expected = json.loads(json.dumps(fixture))
        expected['mutate'] = stage == 'import'
        if stage == 'reopen':
            expected['photos'][0]['rating'] = 0
            expected['photos'][0]['tags'] = []
        fixture_path = out/(stage+'-fixture.json')
        fixture_path.write_text(json.dumps(expected, ensure_ascii=False))
        report_path = out/(stage+'-report.json')
        env = dict(os.environ, FILMDEVELOP_ENGINE=str(root/'build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine'),
                   FILMDEVELOP_DATA_DIR=str(data), FILMDEVELOP_SMOKE_LEGACY_DIR=str(legacy/'PhotoEdits'),
                   FILMDEVELOP_SMOKE_ORGANIZATION=str(fixture_path), FILMDEVELOP_SMOKE_REPORT=str(report_path))
        with (out/(stage+'-stdout.log')).open('w') as stdout, (out/(stage+'-stderr.log')).open('w') as stderr:
            subprocess.run([str(binary)], env=env, stdout=stdout, stderr=stderr, timeout=240, check=True)
        report = json.loads(report_path.read_text())
        assert report['passed'], report
        assert 'DATA RACE' not in (out/(stage+'-stderr.log')).read_text()
        reports.append({'stage': stage, 'report': str(report_path), 'checks': len(report['completed'])})
        saved = json.loads((data/'state/organization.json').read_text())
        assert saved['legacyOrganizationImported']
        # 用舊 Swift 儲存器實讀 Go JSON，驗證欄位延伸不破壞舊格式。
        round_trip = swift_read(data/'state/organization.json')
        for i, photo in enumerate(round_trip['photos']):
            wanted = fixture['photos'][i]
            assert photo['rating'] == (0 if i == 0 else wanted['rating'])
            assert photo['tags'] == ([] if i == 0 else wanted['tags'])
    report = {'passed': True, 'reference': str(out/'swift-reference.json'), 'legacyRecords': len(library['photos']),
              'matchedLocalPhotos': len(paths), 'categories': fixture['tags'], 'desktopRuns': reports,
              'swiftReadsGoRoundTrip': True, 'originalFilesUnchanged': all(digest(Path(p)) == sha for p, sha in before.items())}
    assert report['originalFilesUnchanged']
    (out/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({'passed': True, 'report': str(out/'report.json')}, ensure_ascii=False))
finally:
    assert all(digest(Path(p)) == sha for p, sha in before.items()), '原始照片或使用者資料被修改'
