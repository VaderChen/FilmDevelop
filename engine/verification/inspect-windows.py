#!/usr/bin/env python3
"""檢查 Windows PE 架構、DLL 相依與 Vulkan ABI 匯出；不執行 Windows 程式。"""
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from windows_payload import PE

root=Path(sys.argv[1]).resolve()
paths=sorted(p for p in root.rglob('*') if p.is_file() and p.suffix.lower() in ('.exe','.dll') and 'CMakeFiles' not in p.parts)
if len(paths)<10: raise ValueError('Windows 產物不完整')
results=[]
for path in paths:
    pe=PE(path)
    if pe.machine!=0x8664 or pe.magic!=0x20b: raise ValueError(f'不是 Windows x64 PE：{path}')
    imports=pe.imports()
    if any(x.startswith(('libgcc','libstdc++','libwinpthread')) for x in imports):
        raise ValueError(f'仍相依 MinGW 動態執行環境：{path}: {imports}')
    entry={'file':str(path.relative_to(root)),'architecture':'windows-amd64','imports':imports}
    if path.name.lower()=='libphotocompute.dll':
        functions=pe.exports()
        if set(functions)!={'photo_compute_abi','photo_compute_create','photo_compute_destroy','photo_compute_process','photo_compute_transfers','photo_compute_device_info', 'photo_compute_process_inputs'}:
            raise ValueError(f'PhotoCompute ABI 匯出不符：{functions}')
        entry['exports']=functions
    results.append(entry)
report={'crossCompilationPassed':True,'windowsExecutionVerified':False,'windowsGPUVerified':False,'fullWindowsRendererAvailable':False,'artifacts':results}
(root/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(f'已檢查 {len(results)} 個 Windows PE32+ 產物；尚未執行 Windows 程式。')
