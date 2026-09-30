#!/usr/bin/env python3
"""完整流程 gate 的負向測試，防止缺件／空集合／壞配方被當成驗收通過。"""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

renderer, comparator = (str(Path(p).resolve()) for p in sys.argv[1:])
runner = Path(__file__).with_name("verify_pipeline.py")
with tempfile.TemporaryDirectory(prefix="photocore-pipeline-gate-") as tmp:
    root = Path(tmp)
    pixel = b"PF\n1 1\n-1.0\n" + struct.pack("<3f", .18, .18, .18)
    (root / "input.pfm").write_bytes(pixel)
    (root / "reference.pfm").write_bytes(pixel)
    (root / "recipe.json").write_text(json.dumps({"schema": 1, "isPreview": False, "style": "unsupported-smoke-style"}))
    case = {"id": "unsupported"}
    for field, name in (("input", "input.pfm"), ("recipe", "recipe.json"), ("reference", "reference.pfm")):
        case[field] = name
        case[field + "_sha256"] = hashlib.sha256((root / name).read_bytes()).hexdigest()
    manifest = {"schema": 1, "scope": "full-pipeline-final-output", "metric": "CIEDE2000", "threshold": 2,
                "aggregation": "max", "cases": [case]}
    def run(code):
        (root / "manifest.json").write_text(json.dumps(manifest))
        result = subprocess.run([sys.executable, str(runner), str(root / "manifest.json"), "--renderer", renderer,
                                 "--comparator", comparator, "--report", str(root / "report.json")],
                                capture_output=True, text=True)
        if result.returncode != code:
            raise RuntimeError((result.returncode, result.stdout, result.stderr))
        return json.loads((root / "report.json").read_text()) if code == 1 else None
    unsupported = run(1)
    if unsupported["passed"] or unsupported["measured_cases"] or unsupported["cases"][0]["status"] != "renderer_failed":
        raise RuntimeError("未支援配方不應列為通過")
    (root / "recipe.json").write_text('{}')
    corrupt = run(1)
    if corrupt["cases"][0]["status"] != "invalid_or_incomplete":
        raise RuntimeError("配方 SHA 錯誤未被擋下")
    if corrupt["output_directory"] == unsupported["output_directory"]:
        raise RuntimeError("不得沿用前次產物目錄")
    (root / "input.pfm").unlink()
    if run(1)["cases"][0]["status"] != "invalid_or_incomplete":
        raise RuntimeError("缺少輸入未被擋下")
    manifest["cases"] = []
    run(2)
    manifest["cases"] = [case, case]
    run(2)
    manifest["cases"] = [case]
    manifest["aggregation"] = "mean"
    run(2)
print("完整流程 gate 負向 Smoke 通過；不代表 C++ 引擎色差達標")
