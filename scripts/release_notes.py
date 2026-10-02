#!/usr/bin/env python3
"""從四語共同來源產生逐版 CHANGELOG、README 摘要與 GitHub Release。"""
import argparse
import json
from pathlib import Path
import re

from windows_resources import ROOT, project_version

SOURCE = ROOT / 'desktop/internal/releasenotes/history.json'
REPOSITORY = 'https://github.com/VaderChen/FilmDevelop'
LANGUAGES = {
    'traditionalChinese': ('繁體中文', '', '更新紀錄', '本次更新', '原始碼差異', '驗證紀錄'),
    'english': ('English', '.en', 'Changelog', 'What changed', 'Source comparison', 'Validation record'),
    'japanese': ('日本語', '.ja', '変更履歴', '今回の更新', 'ソースの差分', '検証記録'),
    'korean': ('한국어', '.ko', '변경 기록', '이번 업데이트', '소스 변경 비교', '검증 기록'),
}


def version_key(tag):
    match = re.fullmatch(r'v(\d+)\.(\d+)\.(\d+)-build-(\d+)', tag)
    if not match:
        raise ValueError('更新紀錄的版本標籤無效')
    return tuple(map(int, match.groups()))


def display(tag):
    version_key(tag)
    return tag[1:].replace('-build-', ' build ')


def load_history(require_current=True):
    data = json.loads(SOURCE.read_text())
    if data['schema'] != 1 or not data['releases']:
        raise ValueError('更新紀錄版本或內容無效')
    def translations(value):
        if set(value) != set(LANGUAGES) or any(not isinstance(v, str) or not v.strip() for v in value.values()):
            raise ValueError('更新紀錄缺少四語翻譯')
    for value in data['labels'].values():
        translations(value)
    tags = set()
    for index, entry in enumerate(data['releases']):
        if entry['tag'] in tags or version_key(entry['tag']) <= version_key(entry['previousTag']):
            raise ValueError('更新紀錄重複或比較版本順序錯誤')
        tags.add(entry['tag'])
        if index and data['releases'][index-1]['previousTag'] != entry['tag']:
            raise ValueError('更新紀錄缺少中間版本')
        if not entry['changes'] or not any(c['inApp'] for c in entry['changes']):
            raise ValueError('新版必須提供實際變更與程式內摘要')
        for change in entry['changes']:
            translations(change['text'])
            if change['kind'] not in ('added', 'fixed', 'improved') or type(change['inApp']) is not bool:
                raise ValueError('更新項目類型無效')
            if not set(change.get('platforms', [])) <= {'darwin', 'windows'}:
                raise ValueError('更新項目的平台無效')
    if require_current:
        version = project_version()
        if data['releases'][0]['tag'] != f"v{version['version']}-build-{version['build']}":
            raise ValueError('尚未填寫目前版本的更新紀錄；不可沿用上一版摘要')
    return data


def release_section(data, entry, language, links=True):
    _, _, _, _, comparison, verification = LANGUAGES[language]
    labels = data['labels']
    lines = [labels['comparison'][language] + '**' + display(entry['previousTag']) + '**。', '']
    for change in entry['changes']:
        platform = {'darwin': 'macOS', 'windows': 'Windows'}
        scope = ' / '.join(platform[p] for p in change.get('platforms', []))
        prefix = labels[change['kind']][language] + (' · ' + scope if scope else '')
        lines.append(f"- **{prefix}**：{change['text'][language]}")
    if links:
        lines.extend(['', f"[{comparison}]({REPOSITORY}/compare/{entry['previousTag']}...{entry['tag']}) · "
                      f"[{verification}]({REPOSITORY}/blob/{entry['tag']}/desktop/RESTORATION.md)"])
    return '\n'.join(lines)


def generated_files(data):
    files = {}
    latest = data['releases'][0]
    for language, (name, suffix, title, latest_title, _, _) in LANGUAGES.items():
        nav = ' · '.join(f'[{v[0]}](CHANGELOG{v[1]}.md)' for v in LANGUAGES.values())
        sections = [f'# {title}', '', nav, '', '<!-- 由 scripts/release_notes.py 產生；請修改 history.json。 -->']
        for entry in data['releases']:
            sections += ['', f"## {display(entry['tag'])}", '', release_section(data, entry, language)]
        sections += ['', f'[Swift · {title} (繁體中文)](CHANGELOG.swift.md)']
        files[ROOT / f'CHANGELOG{suffix}.md'] = '\n'.join(sections) + '\n'
        readme = ROOT / f'README{suffix}.md'
        original = readme.read_text()
        original = re.sub(r'\*\*\d+\.\d+\.\d+ build \d+\*\*', '**' + display(latest['tag']) + '**', original, count=1)
        block = '<!-- release-summary:start -->\n' + f'## {latest_title}\n\n' + release_section(data, latest, language, False)
        block += f"\n\n[{data['labels']['changelog'][language]}](CHANGELOG{suffix}.md)\n<!-- release-summary:end -->"
        pattern = r'<!-- release-summary:start -->.*?<!-- release-summary:end -->'
        if re.search(pattern, original, re.S):
            original = re.sub(pattern, lambda _: block, original, flags=re.S)
        else:
            # 摘要放在下載說明後、功能介紹前；只首次插入，其後依明確標記更新。
            positions = list(re.finditer(r'^## ', original, re.M))
            if len(positions) < 2:
                raise ValueError('README 缺少摘要插入位置')
            at = positions[1].start()
            original = original[:at] + block + '\n\n' + original[at:]
        files[readme] = original
    files[ROOT / 'RELEASE_NOTES.md'] = release_body(data, latest['tag'])
    return files


def release_body(data, tag):
    entry = next((r for r in data['releases'] if r['tag'] == tag), None)
    if not entry:
        raise ValueError('找不到指定版本的更新紀錄')
    version, build = tag[1:].split('-build-')
    portable = version_key(tag) >= version_key('v1.26.1002-build-2330')
    windows = f'FilmDevelop-{version}-build{build}-windows-x64-' + ('portable.zip' if portable else 'setup.exe')
    download = REPOSITORY + '/releases/download/' + tag + '/'
    parts = [' · '.join(f'[{v[0]}](#{v[0].lower()})' for v in LANGUAGES.values()), '',
             f'[macOS Apple Silicon DMG]({download}FilmDevelop-{version}-build{build}-macos-arm64.dmg) · '
             f'[Windows x64 Beta]({download}{windows}) · '
             f'[Swift Mac upgrade]({download}FilmYourPhoto-{version}-build-{build}-arm64.dmg) · '
             f'[SHA-256]({download}SHA256SUMS.txt)', '']
    for language, (name, suffix, _, _, _, verification) in LANGUAGES.items():
        parts += [f'## {name}', '', release_section(data, entry, language), '',
                  f"[{data['labels']['changelog'][language]}]({REPOSITORY}/blob/{data['releases'][0]['tag']}/CHANGELOG{suffix}.md) · "
                  f'[README]({REPOSITORY}/blob/{tag}/README{suffix}.md) · '
                  f'[{verification} (JSON)]({download}release-validation.json)', '']
    # 不重複 Release 標題；安裝相容性、已知限制與逐版測試均由對應版本文件提供。
    return '\n'.join(parts)


def check_files(data, write=False):
    for path, content in generated_files(data).items():
        if write:
            path.write_text(content)
        elif not path.is_file() or path.read_text() != content:
            raise ValueError(f'更新紀錄尚未同步：{path.relative_to(ROOT)}；請執行 --write')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--write', action='store_true')
    mode.add_argument('--check', action='store_true')
    mode.add_argument('--release', metavar='TAG')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    data = load_history()
    if args.release:
        content = release_body(data, args.release)
        if args.output:
            args.output.write_text(content)
        else:
            print(content)
    else:
        check_files(data, args.write)
        print('四語更新紀錄與 README 已' + ('同步' if args.write else '驗證'))


if __name__ == '__main__':
    main()
