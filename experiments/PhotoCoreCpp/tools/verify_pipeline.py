#!/usr/bin/env python3
"""完整流程驗收：每組配方必須由 C++ 重新執行，禁止略過缺件或沿用舊成品。"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(manifest_path, renderer, comparator, report_path, expected_scope="full-pipeline-final-output"):
    manifest_path, renderer, comparator, report_path = map(
        lambda p: Path(p).resolve(), (manifest_path, renderer, comparator, report_path))
    root = manifest_path.parent
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get("schema") != 1 or manifest.get("scope") != expected_scope
            or manifest.get("metric") != "CIEDE2000" or manifest.get("threshold") != 2
            or manifest.get("aggregation") != "max"):
        raise ValueError("驗收契約必須是完整最終成品、CIEDE2000、每像素最大值 < 2")
    cases = manifest.get("cases")
    if not isinstance(cases, list) or not cases:
        raise ValueError("缺少完整流程案例，不能算通過")
    ids = [case["id"] for case in cases]
    if len(set(ids)) != len(ids) or any(not re.fullmatch(r"[A-Za-z0-9_-]+", i) for i in ids):
        raise ValueError("案例 ID 重複或不合法")
    if not renderer.is_file() or not comparator.is_file():
        raise ValueError("缺少 C++ 執行檔或色差比較器")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="pipeline-run-", dir=report_path.parent))
    results = []
    checked = {}
    for case in cases:
        result = {"id": case["id"], "passed": False}
        try:
            paths = {}
            for field in ["input", "recipe", "reference"] + (["camera_original"] if "camera_original" in case else []):
                p = (root / case[field]).resolve()
                if not p.is_relative_to(root):
                    raise ValueError("測試檔案不得超出 fixture 目錄")
                expected = case[field + "_sha256"]
                if p not in checked:
                    checked[p] = digest(p)
                actual = checked[p]
                if actual != expected:
                    raise ValueError(f"{field} SHA-256 不符；禁止混用舊配方／參考圖")
                paths[field] = p
            recipe = json.loads(paths["recipe"].read_text())
            if recipe.get("schema") != 1 or recipe.get("isPreview") is not False:
                raise ValueError("必須使用完整成品配方，不能使用預覽模式")
            target = output / (case["id"] + ".pfm")
            command = [str(renderer), "--input", str(paths["input"]), "--recipe", str(paths["recipe"]),
                       "--output", str(target)]
            if "camera_original" in paths:
                command += ["--camera-original", str(paths["camera_original"])]
            rendered = subprocess.run(command, capture_output=True, text=True, timeout=180)
            if rendered.returncode != 0:
                result.update(status="renderer_failed", error=(rendered.stderr or rendered.stdout)[-2000:])
            elif not target.is_file():
                result.update(status="missing_output", error="C++ 回報成功卻沒有最終成品")
            else:
                measured = subprocess.run([str(comparator), str(paths["reference"]), str(target)],
                                          capture_output=True, text=True, timeout=180)
                if measured.returncode not in (0, 1):
                    result.update(status="comparison_failed", error=measured.stderr[-2000:])
                else:
                    metrics = json.loads(measured.stdout)
                    result.update(status="measured", metrics=metrics, output_sha256=digest(target),
                                  passed=measured.returncode == 0 and metrics["passed"] is True
                                  and metrics["max"] < 2 and metrics["pixels_at_or_above_2"] == 0)
        except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
            result.update(status="invalid_or_incomplete", error=str(error))
        results.append(result)
    passed = all(row["passed"] for row in results)
    report = {"schema": 1, "scope": expected_scope, "passed": passed, "metric": "CIEDE2000", "threshold": 2,
              "aggregation": "max", "total": len(results),
              "passed_cases": sum(row["passed"] for row in results),
              "measured_cases": sum(row.get("status") == "measured" for row in results),
              "manifest_sha256": digest(manifest_path), "renderer_sha256": digest(renderer),
              "comparator_sha256": digest(comparator),
              "renderer_data_sha256": {p.name: digest(p) for p in (renderer.parent / "film-data").glob("*") if p.is_file()}, "output_directory": str(output), "cases": results}
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    label = "App 完整流程" if expected_scope == "full-pipeline-final-output" else "底片／顯影／掃描串接"
    print(f"{label}驗收：{'通過' if passed else '未通過'}，{report['passed_cases']}/{len(results)}；"
          f"取得色差結果 {report['measured_cases']} 組。報告：{report_path}")
    return 0 if passed else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest")
    parser.add_argument("--scope", choices=["full-pipeline-final-output", "film-development-scanner"], default="full-pipeline-final-output")
    parser.add_argument("--renderer", required=True)
    parser.add_argument("--comparator", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    try:
        return verify(args.manifest, args.renderer, args.comparator, args.report, args.scope)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(2, f"驗收設定錯誤：{error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
