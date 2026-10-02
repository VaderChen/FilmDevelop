#!/usr/bin/env python3
"""封裝 Windows 本機主體分割與景深模型；固定來源與 SHA-256。"""
import hashlib
from pathlib import Path
import shutil
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
MODELS = [
    ('ultraface.onnx', 'https://huggingface.co/onnxmodelzoo/version-RFB-320/resolve/6fd293d22b523ec88959f104b8eef5395e3adfbc/version-RFB-320.onnx', '34cd7e60aeff28744c657de7a3dc64e872d506741de66987f3426f2b79f88017'),
    ('u2netp.onnx', 'https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2netp.onnx', '309c8469258dda742793dce0ebea8e6dd393174f89934733ecc8b14c76f4ddd8'),
    ('depth-anything-v2-small.onnx', 'https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/4472b7362082ad9968fee890ca0f1e5aca36b93d/onnx/model.onnx', 'afb6a5c28f3b6bf1618c6e43f02073ef9dfdc70e937502d51603e57b0a1df10c'),
]

def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT/'build/windows-cross/vision')
    cache = ROOT/'build/parity-ai'
    cache.mkdir(parents=True, exist_ok=True)
    (out/'models').mkdir(parents=True, exist_ok=True)
    (out/'Licenses').mkdir(exist_ok=True)
    for name, url, expected in MODELS:
        path = cache/name
        if not path.is_file():
            temporary = path.with_suffix('.part')
            with urllib.request.urlopen(url, timeout=90) as response, temporary.open('wb') as target:
                shutil.copyfileobj(response, target)
            temporary.replace(path)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f'視覺模型雜湊不符：{name}')
        shutil.copy2(path, out/'models'/name)
    # 主體與景深原始模型採 Apache 2.0，人臉模型採 MIT；ONNX 轉換使用 rembg（MIT）與 Transformers（Apache 2.0）。
    notices = ['Windows 本機視覺模型\n']
    for name, url, expected in MODELS:
        notices.append(f'{name}\n來源：{url}\nSHA-256：{expected}\n')
    notices.append('U²-Net：Copyright 2020 Xuebin Qin et al.，Apache-2.0\nDepth Anything V2 Small：Copyright 2024 Depth Anything，Apache-2.0\nUltraFace：Copyright 2019 Linzaer，MIT，https://github.com/Linzaer/Ultra-Light-Fast-Generic-Face-Detector-1MB\n轉換來源：https://github.com/danielgatis/rembg 與 https://huggingface.co/onnx-community/depth-anything-v2-small\n')
    (out/'Licenses/NOTICE.txt').write_text('\n'.join(notices), encoding='utf-8')
    shutil.copy2(ROOT/'packaging/windows/licenses/Apache-2.0.txt', out/'Licenses/Apache-2.0.txt')
    shutil.copy2(ROOT/'packaging/windows/licenses/UltraFace-MIT.txt', out/'Licenses/UltraFace-MIT.txt')
    print(f'Windows 主體與景深模型已驗證：{out}')

if __name__ == '__main__':
    main()
