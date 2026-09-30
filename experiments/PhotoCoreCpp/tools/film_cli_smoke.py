#!/usr/bin/env python3
"""確認 CPU 底片輸入契約、來源保護與錯誤拒絕；不取代色差驗收。"""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
exe=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="photocore-film-") as tmp:
    root=Path(tmp)
    source=root/'來源.pfm'
    source.write_bytes(b'PF\n4 1\n-1.0\n'+struct.pack('<12f',0,0,0,.18,.18,.18,1,0,0,4,2,1))
    recipe=root/'配方.json';output=root/'成品.pfm'
    base={"schema":1,"scope":"film-development-scanner","style":"filmPortra400","isPreview":False,"strength":1,"effects":{}}
    def run(code,extra=()):
        cmd=[str(exe),'--input',str(source),'--recipe',str(recipe),'--output',str(output),*extra]
        r=subprocess.run(cmd,capture_output=True,text=True)
        if r.returncode!=code:raise RuntimeError((r.returncode,r.stdout,r.stderr))
    recipe.write_text(json.dumps(base));before=hashlib.sha256(source.read_bytes()).hexdigest()
    run(0)
    if not output.read_bytes().startswith(b'PF\n4 1\n-1.0\n'):raise RuntimeError('輸出大小不符')
    run(1,('--output',str(source)))
    run(1,('--output',str(recipe)))
    if hashlib.sha256(source.read_bytes()).hexdigest()!=before:raise RuntimeError('來源被覆寫')
    for update in ({'scope':'full-pipeline-final-output'},{'isPreview':True},{'style':'unknown-film'},
                   {'effects':{'scanner_profile':'unknown'}},{'effects':{'development_amount':'abc'}},
                   {'effects':{'development_amount':None}},{'effects':{'typo_parameter':1}},
                   {'effects':{'developer_chemistry':{'speedEV':'bad'}}}):
        recipe.write_text(json.dumps(base|update))
        # 明確 null 按照可選參數契約回退至預設，其餘無效型別必須拒絕。
        run(0 if update=={'effects':{'development_amount':None}} else 1)
print('CPU 底片命令列 Smoke 通過')
