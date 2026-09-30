#!/usr/bin/env python3
"""以既有 Swift 參考成品驗證 GPU unmix 與 CPU 三模組串接，使用全新輸出目錄。"""
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile

from verify_pipeline import digest, verify


SELECTION = {
    "film-fixtures": [
        "image-0-filmPortra400-default", "image-1-filmPortra400-default",
        "image-0-filmEktar100-scanner", "image-1-filmEktar100-scanner",
        "image-0-filmLomoPurple-default", "image-1-filmBleachBypass-silver",
        "image-0-filmVision500T-development"],
    "film-branches-fixtures": ["image-1-filmPortra800-exposure"],
    "film-odd-fixtures": ["image-0-filmPortra400-development", "image-1-filmPortra400-development"],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--environment", type=Path, required=True)
    args = parser.parse_args()
    build = args.build.resolve()
    environment = json.loads(args.environment.read_text())
    allowed = {"VK_DRIVER_FILES", "VK_LAYER_PATH", "MVK_CONFIG_FAST_MATH_ENABLED", "MVK_CONFIG_LOG_LEVEL"}
    if set(environment) != allowed or environment["MVK_CONFIG_FAST_MATH_ENABLED"] != "0":
        raise ValueError("請使用 configure_vulkan_macos.py 產生的嚴格浮點環境")
    os.environ.update(environment)
    run = Path(tempfile.mkdtemp(prefix="matrix-", dir=build))
    fixtures = run / "fixtures"
    fixtures.mkdir()
    cases = []
    provenance = {}
    for collection, ids in SELECTION.items():
        source = (args.fixtures / collection).resolve()
        manifest_path = source / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        if any(manifest.get(k) != v for k, v in {
                "schema": 1, "scope": "film-development-scanner", "metric": "CIEDE2000",
                "threshold": 2, "aggregation": "max"}.items()):
            raise ValueError("原始參考資料驗收契約不符")
        provenance[collection] = digest(manifest_path)
        for identifier in ids:
            matches = [c for c in manifest["cases"] if c["id"] == identifier]
            if len(matches) != 1:
                raise ValueError(f"參考案例缺少或重複：{identifier}")
            case = dict(matches[0])
            case["id"] = collection + "-" + identifier
            for field in ("input", "recipe", "reference"):
                original = (source / case[field]).resolve()
                if not original.is_relative_to(source) or digest(original) != case[field + "_sha256"]:
                    raise ValueError(f"參考資料 SHA-256 或路徑不符：{identifier}/{field}")
                destination = fixtures / (collection + "-" + original.name)
                shutil.copyfile(original, destination)
                case[field] = destination.name
            cases.append(case)
    manifest_path = fixtures / "manifest.json"
    manifest_path.write_text(json.dumps({"schema": 1, "scope": "film-development-scanner",
        "metric": "CIEDE2000", "threshold": 2, "aggregation": "max", "cases": cases}, indent=2) + "\n")
    report_path = run / "report.json"
    status = verify(manifest_path, build / "photo_core_vulkan_smoke", build / "photo_core_compare",
                    report_path, "film-development-scanner")
    report = json.loads(report_path.read_text())
    for case in report["cases"]:
        try:
            sidecar = Path(report["output_directory"]) / (case["id"] + ".pfm.gpu.json")
            gpu = json.loads(sidecar.read_text())
            case["gpu"] = gpu
            if not (gpu["passed"] and gpu["gpu_elements"] > 0
                    and gpu["scope"] == "gpu-unmix-cpu-film-development-scanner"
                    and gpu["gpu_arithmetic"] == "FP32" and gpu["synchronization_validation"]
                    and gpu["cpu_fallback_calls_in_replay"] == 0 and gpu["validation_errors"] == 0
                    and gpu["guard_and_repeat_checks"] and gpu["cpu_vs_hybrid_max_delta_e00"] < 2
                    and gpu["max_unmix_component_error"] < 0.001):
                raise ValueError("GPU 路徑或精度驗收未通過")
        except (OSError, KeyError, ValueError) as error:
            case.update(passed=False, gpu_error=str(error))
    report["passed"] = status == 0 and all(c["passed"] for c in report["cases"])
    report["passed_cases"] = sum(c["passed"] for c in report["cases"])
    report["gpu_scope"] = "只有 unmix 在 GPU 執行，其餘為 CPU；非 App 完整流程，非整體效率驗證"
    report["source_manifest_sha256"] = provenance
    report["shader_sha256"] = digest(build / "unmix.comp.spv")
    report["runtime_environment"] = environment
    root = Path(__file__).resolve().parents[1]
    report["source_sha256"] = {str(p.relative_to(root)): digest(p) for folder in
        ("src", "include", "vulkan_smoke", "verification", "tools") for p in (root / folder).rglob("*")
        if p.is_file() and p.suffix in (".cpp", ".hpp", ".comp", ".py")}
    driver = json.loads(Path(environment["VK_DRIVER_FILES"]).read_text())
    layer = json.loads((Path(environment["VK_LAYER_PATH"]) / "VkLayer_khronos_validation.json").read_text())
    report["runtime_sha256"] = {p: digest(Path(p)) for p in
        (driver["ICD"]["library_path"], layer["layer"]["library_path"])}
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"GPU 串接 Smoke：{report['passed_cases']}/{report['total']}，報告：{report_path}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
