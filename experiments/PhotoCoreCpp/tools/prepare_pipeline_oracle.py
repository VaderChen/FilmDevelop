#!/usr/bin/env python3
"""只在獨立測試副本加入錯誤／步驟記錄，不變更產品的影像運算。"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root, output = (Path(v).resolve() for v in sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
processor = (root / "PhotoStyleApp/PhotoStyleProcessor.swift").read_text()
old = """        } catch {
            // 失敗必須傳回呼叫端；預覽保留上一張成品，匯出不得誤存原片。
            throw error
        }"""
new = old.replace("            throw error", "            PipelineOracleTrace.failed = true\n            throw error")
if processor.count(old) != 1:
    raise SystemExit("產品錯誤處理入口改變，須更新參考工具；不能默默沿用舊入口")
(output / "PhotoStyleProcessor.swift").write_text(processor.replace(old, new))
pipeline = (root / "PhotoStyleApp/PhotoProcessingPipeline.swift").read_text()
for signature in ("func process(_ name: String, _ transform: (CIImage) throws -> CIImage) throws {",
                  "func inspect<T>(_ name: String, _ body: (CIImage) throws -> T) throws -> T {"):
    if pipeline.count(signature) != 1:
        raise SystemExit("產品流程入口改變，須更新步驟記錄")
    pipeline = pipeline.replace(signature, signature + "\n        PipelineOracleTrace.stages.append(name)")
(output / "PhotoProcessingPipeline.swift").write_text(pipeline)
paths = list((root / "PhotoStyleShared/Sources").rglob("*"))
paths += [root / "PhotoStyleApp" / name for name in ("PhotoImage.swift", "PhotoWebPEncoder.swift", "PhotoStyle.swift",
          "Comparable+Clamped.swift", "PhotoStyleProcessor.swift", "PhotoProcessingPipeline.swift", "PhotoComputeBackend.swift", "PhotoDateStampRenderer.swift")]
paths += list((root / "experiments/PhotoCoreCpp/tools").glob("*"))
sources = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
           for p in sorted(paths) if p.is_file() and not p.name.startswith(".") and p.suffix != ".bak"}
(output.parent / "oracle-provenance.json").write_text(json.dumps({
    "git_head": subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
    "swift": subprocess.check_output(["swift", "--version"], text=True).strip(),
    "sources": sources,
    "instrumentation": "測試副本只增加 process/inspect 名稱記錄與 catch 失敗旗標，運算內容不變。"
}, ensure_ascii=False, indent=2) + "\n")
