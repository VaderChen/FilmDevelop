#!/usr/bin/env python3
"""真正 GPU dispatch 的 CTest；環境缺件、未呼叫反算或成品不符均視為失敗。"""
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

exe = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='photocore-vulkan-') as directory:
    root = Path(directory)
    source = root / '來源.pfm'
    pixels = []
    for y in range(4, -1, -1):
        for x in range(17):
            gain = 2 ** (-8 + x * .75)
            pixels.extend((gain * (1 if y % 2 else .1), gain * .3, gain * (1 if y > 2 else .2)))
    source.write_bytes(b'PF\n17 5\n-1.0\n' + struct.pack('<255f', *pixels))
    recipe = root / '調整.json'
    data = {'schema': 1, 'scope': 'film-development-scanner', 'style': 'filmPortra400',
            'isPreview': False, 'strength': 1, 'effects': {}}
    recipe.write_text(json.dumps(data))
    output = root / '成品.pfm'
    command = [str(exe), '--input', str(source), '--recipe', str(recipe), '--output', str(output)]
    completed = subprocess.run(command + ['--benchmark-repeats', '1'], capture_output=True, text=True, timeout=120)
    if completed.returncode:
        raise RuntimeError(completed.stderr)
    report = json.loads(Path(str(output) + '.gpu.json').read_text())
    assert report['passed'] and report['gpu_elements'] == 85
    assert report['guard_and_repeat_checks'] and report['validation_errors'] == 0
    assert report['synchronization_validation'] and report['cpu_fallback_calls_in_replay'] == 0
    assert report['cpu_vs_hybrid_max_delta_e00'] < 2
    assert len(report['benchmark']['runs']) == 1
    assert report['benchmark']['first_gpu_run']['dispatches'] == 1
    assert report['benchmark']['runs'][0]['gpu']['max_component_error'] < 0.001
    # 再次使用成品路徑必須拒絕；無 unmix 的正片不可假裝通過 GPU Smoke。
    assert subprocess.run(command, capture_output=True).returncode != 0
    data['style'] = 'filmVelvia50'
    recipe.write_text(json.dumps(data))
    command[-1] = str(root / '正片.pfm')
    rejected = subprocess.run(command, capture_output=True, text=True, timeout=120)
    assert rejected.returncode != 0 and '未執行彩色負片 unmix' in rejected.stderr
    assert not Path(command[-1]).exists()
print('Vulkan Compute／FP32／邊界／同步驗證／拒絕路徑 Smoke 通過')
