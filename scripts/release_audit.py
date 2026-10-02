#!/usr/bin/env python3
"""發布前檢查：不允許私人建置路徑、私鑰或常見存取權杖進入成品。"""
import argparse
import json
from pathlib import Path
import re

PATTERNS = {
    'personal-path': re.compile(rb'/Users/[^/\s"<>]{1,80}/|/Volumes/[^/\s"<>]{1,80}/|[A-Za-z]:[\\/]Users[\\/][^\\/\s"]{1,80}[\\/]'),
    'private-key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'access-token': re.compile(rb'(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[A-Z0-9]{16}|sk-(?:proj-)?[A-Za-z0-9_-]{40,})(?![A-Za-z0-9_])'),
}


def audit(root):
    root = Path(root)
    findings, checked = [], 0
    for path in sorted(root.rglob('*')) if root.is_dir() else [root]:
        if not path.is_file() or path.is_symlink():
            continue
        checked += 1
        if path.name == 'pack.command':
            findings.append({'file': str(path.relative_to(root)) if root.is_dir() else path.name, 'kind': 'local-only-script'})
        data = path.read_bytes()
        # 同時涵蓋 Windows UTF-16 字串；只回報種類與相對檔名，不輸出敏感值。
        wide = data.replace(b'\0', b'')
        for kind, pattern in PATTERNS.items():
            if pattern.search(data) or pattern.search(wide):
                findings.append({'file': str(path.relative_to(root)) if root.is_dir() else path.name, 'kind': kind})
    if findings:
        raise ValueError('發布隱私檢查未通過：'+json.dumps(findings, ensure_ascii=False))
    return {'passed': True, 'filesChecked': checked}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    args = parser.parse_args()
    print(json.dumps(audit(args.root), ensure_ascii=False))
