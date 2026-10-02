#!/usr/bin/env python3
"""封裝既有 Web 介面，保留 Swift 與 Go 的共同來源。"""
from pathlib import Path
import json
import shutil
from windows_resources import project_version
from release_notes import load_history

root = Path(__file__).resolve().parents[1]
load_history()  # 升版時未填差異，立即停止建置，避免再次顯示舊摘要。
source = root / 'PhotoStyleApp/Web'
target = root / 'desktop/frontend/dist'
target.mkdir(parents=True, exist_ok=True)
for file in source.iterdir():
    if file.is_file() and file.suffix in ('.js', '.css', '.html', '.svg', '.png', '.jpg', '.woff2'):
        shutil.copyfile(file, target / file.name)
shutil.copyfile(root / 'desktop/frontend/bridge.js', target / 'bridge.js')
page = (target / 'index.html').read_text()
page = page.replace('<script src="app.js', '<script src="bridge.js"></script>\n<script src="app.js')
version = project_version()
translations = json.loads((source / 'localization-data.js').read_text().split('=', 1)[1].strip().removesuffix(';'))
(root / 'desktop/internal/application/localization.json').write_text(json.dumps(translations, ensure_ascii=False) + '\n')
(root / 'desktop/internal/application/version.json').write_text(json.dumps(dict(version=version['version'], build=version['build'])) + '\n')
app_info = dict(version=version['version'], build=version['build'], configuration='RELEASE',
                isDebug=False, systemLanguage='', languagePreference='')
page = page.replace('</head>', '<script>window.__appInfo=' + json.dumps(app_info, ensure_ascii=False) + ';</script></head>')
(target / 'index.html').write_text(page)

print('已封裝共用 Web 介面')
