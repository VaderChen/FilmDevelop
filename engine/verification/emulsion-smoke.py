#!/usr/bin/env python3
"""驗證 macOS 乳劑晶體共用的邊界、HDR、分塊與暖機耗時。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "PhotoStyleShared/Sources/PhotoStyleShared/PhotoEmulsionExposureProcessor.swift"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-source", type=Path, default=SOURCE,
                        help="可指定修改前的乳劑 Swift 原始碼，預設使用保留的原演算法")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    (ROOT / "build").mkdir(exist_ok=True)
    output = args.output or Path(tempfile.mkdtemp(prefix="emulsion-smoke-", dir=ROOT / "build"))
    output.mkdir(parents=True, exist_ok=True)
    binary = output / "emulsion-smoke"
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library",
                    str(Path(__file__).with_suffix(".swift")), "-o", str(binary)], check=True)
    (output / "report.json").unlink(missing_ok=True)
    result = subprocess.run([str(binary), str(SOURCE), str(args.reference_source), str(output / "report.json")])
    if (output / "report.json").exists():
        report = json.loads((output / "report.json").read_text())
        report["sourceSHA256"] = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
        report["referenceSHA256"] = hashlib.sha256(args.reference_source.read_bytes()).hexdigest()
        (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"驗證紀錄：{output / 'report.json'}", flush=True)
    result.check_returncode()


if __name__ == "__main__":
    main()
