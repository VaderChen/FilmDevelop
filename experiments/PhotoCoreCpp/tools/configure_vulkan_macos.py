#!/usr/bin/env python3
"""建立本機 Smoke 的 Vulkan manifest 副本，避免依賴 DYLD_LIBRARY_PATH；不修改系統檔案。"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory', type=Path)
args = parser.parse_args()
if sys.platform != 'darwin':
    parser.error('此設定工具僅處理 macOS Homebrew；其他平台請使用當地 Vulkan 驅動')
root = args.directory.resolve()
root.mkdir(parents=True, exist_ok=True)
layers = root / 'layers'
layers.mkdir(exist_ok=True)
prefix = lambda name: Path(subprocess.check_output(['brew', '--prefix', name], text=True).strip()).resolve()
molten, validation = prefix('molten-vk'), prefix('vulkan-validationlayers')
driver_path = molten / 'etc/vulkan/icd.d/MoltenVK_icd.json'
driver = json.loads(driver_path.read_text())
driver['ICD']['library_path'] = str((driver_path.parent / driver['ICD']['library_path']).resolve(strict=True))
layer = json.loads((validation / 'share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json').read_text())
layer['layer']['library_path'] = str((validation / 'lib/libVkLayer_khronos_validation.dylib').resolve(strict=True))
(root / 'MoltenVK_icd.json').write_text(json.dumps(driver, indent=2) + '\n')
(layers / 'VkLayer_khronos_validation.json').write_text(json.dumps(layer, indent=2) + '\n')
environment = {'VK_DRIVER_FILES': str(root / 'MoltenVK_icd.json'), 'VK_LAYER_PATH': str(layers),
               'MVK_CONFIG_FAST_MATH_ENABLED': '0', 'MVK_CONFIG_LOG_LEVEL': '1'}
(root / 'environment.json').write_text(json.dumps(environment, indent=2) + '\n')
(root / 'vulkan.env').write_text(''.join(f'export {key}={shlex.quote(value)}\n' for key, value in environment.items()))
print('已建立本機 Vulkan 環境：', root / 'vulkan.env')
