#!/usr/bin/env python3
"""收集桌面執行檔實際使用的 Go 模組授權，包含兩個目標平台。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root=Path(__file__).resolve().parents[1]
target=Path(sys.argv[1]).resolve();target.mkdir(parents=True,exist_ok=True)
modules={};package_dirs={};decoder=json.JSONDecoder()
for platform in ('darwin','windows'):
    env=dict(os.environ,GOOS=platform,GOARCH='arm64' if platform=='darwin' else 'amd64',CGO_ENABLED='1' if platform=='darwin' else '0')
    raw=subprocess.check_output(['go','-C',str(root/'desktop'),'list','-deps','-json','-tags','desktop,production','./cmd/filmdevelop-desktop'],env=env,text=True)
    while raw.strip():
        raw=raw.lstrip();package,n=decoder.raw_decode(raw);raw=raw[n:]
        module=package.get('Module')
        if module and not module.get('Main'):
            modules[module['Path']]=module
            package_dirs.setdefault(module['Path'],set()).add(Path(package['Dir']))
index=[]
for name,module in sorted(modules.items()):
    directory=Path(module['Dir'])
    # 原生 Loader 等子套件可能使用不同授權；收集實際編入套件的祖先目錄。
    directories={directory}
    for package_dir in package_dirs[name]:
        while package_dir!=directory:
            package_dir.relative_to(directory)
            directories.add(package_dir)
            package_dir=package_dir.parent
    files=sorted({p for folder in directories for p in folder.iterdir()
                  if p.is_file() and p.name.lower().startswith(('license','copying','notice','copyright'))})
    if not files: raise SystemExit('找不到模組授權：'+name)
    destination=target/(name.replace('/','_')+'@'+module['Version']);destination.mkdir(exist_ok=True)
    for path in files:
        output=destination/path.relative_to(directory)
        output.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(path,output)
    index.append({'module':name,'version':module['Version'],
                  'licenses':[str((destination/p.relative_to(directory)).relative_to(target)) for p in files]})
goroot=Path(subprocess.check_output(['go','env','GOROOT'],text=True).strip())
license=next((path for path in [goroot/'LICENSE',goroot.parent/'LICENSE'] if path.is_file()),None)
if license is None: raise SystemExit('找不到 Go 工具鏈授權')
shutil.copyfile(license,target/'Go-LICENSE')
(target/'index.json').write_text(json.dumps(index,ensure_ascii=False,indent=2)+'\n')
print(f'已收集 {len(index)} 個桌面相依模組及 Go 的授權。')
