#!/usr/bin/env python3
"""以真正的交叉編譯產物測試封裝檢查器；不執行 Windows 程式。"""
import argparse
import importlib.util
import json
from pathlib import Path
import struct
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from windows_payload import PE, validate_gui, validate_payload
from windows_resources import project_version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=ROOT / 'build/windows-cross')
    args = parser.parse_args()
    build = args.build_dir.resolve()
    checks = []

    def rejects(label, function, reason):
        try:
            function()
        except ValueError as error:
            if reason not in str(error):
                raise AssertionError(f'{label}：非預期錯誤：{error}') from error
            checks.append({'name': label, 'passed': True})
        else:
            raise AssertionError(f'{label} 未拒絕不合法的安裝內容')

    gui = build / 'bin/FilmDevelopGo.exe'
    info = project_version()
    validate_gui(gui, info, build / 'resources/FilmDevelop.exe.manifest')
    if PE(gui).imports() != ['kernel32.dll']:
        raise AssertionError('Go 桌面 PE 的靜態匯入已改變，請核對新的相依關係')
    checks.append({'name': '實際 Go GUI 的版本、圖示、Manifest 與匯入表', 'passed': True})

    with tempfile.TemporaryDirectory(prefix='FilmDevelop Windows 測試 ') as temporary:
        folder = Path(temporary)
        engine = folder / 'engine'
        engine.mkdir()
        target = engine / 'libPhotoCompute.dll'
        original = (build / 'core/libPhotoCompute.dll').read_bytes()
        target.write_bytes(original)
        report = validate_payload(folder)
        if report[0]['imports'].get('vulkan-1.dll') != 'gpu-driver':
            raise AssertionError('Vulkan 驅動未列為外部必要條件')
        checks.append({'name': '真正 C++ DLL 的 ABI、靜態相依與 Unicode／空白路徑', 'passed': True})

        damaged = bytearray(original)
        struct.pack_into('<H', damaged, PE(target).header + 4, 0xaa64)
        target.write_bytes(damaged)
        rejects('拒絕混入 ARM64', lambda: validate_payload(folder), '非 x64')

        if b'KERNEL32.dll\0' not in original:
            raise AssertionError('找不到負向測試用的實際 DLL 匯入')
        target.write_bytes(original.replace(b'KERNEL32.dll\0', b'MISSINGX.dll\0', 1))
        rejects('拒絕遺漏執行期 DLL', lambda: validate_payload(folder), '缺少 DLL')

        target.write_bytes(original)
        target.rename(folder / 'wrong-module.dll')
        rejects('不可將 GPU 驅動例外套用到其他模組', lambda: validate_payload(folder), '缺少 DLL')
        (folder / 'wrong-module.dll').unlink()

        # AI DLL 的 VC++ 相依必須有可執行的安裝前置步驟，不可誤列為 Windows 內建。
        target.write_bytes(original.replace(b'vulkan-1.dll\0', b'msvcp140.dll\0', 1))
        rejects('拒絕缺少 VC++ 安裝前置條件', lambda: validate_payload(folder), '缺少 DLL')
        prerequisites = folder / 'Prerequisites'
        prerequisites.mkdir()
        for name in ('prerequisites.json', 'ensure-prerequisites.ps1'):
            shutil.copy2(ROOT / 'packaging/windows' / name, prerequisites / name)
        report = validate_payload(folder)
        if not report[0]['imports']['msvcp140.dll'].startswith('prerequisite:'):
            raise AssertionError('VC++ 執行環境沒有由安裝程式負責')
        checks.append({'name': 'VC++ 執行環境由可驗證的前置安裝提供', 'passed': True})
        target.unlink()

        wrong_version = dict(info, numericVersion='0.0.0.0')
        rejects('拒絕舊版 GUI 混入新版安裝包', lambda: validate_gui(gui, wrong_version), '版本或旗標不符')
        broken = folder / 'truncated.exe'
        broken.write_bytes(b'MZ')
        rejects('拒絕截斷的 PE', lambda: PE(broken), '截斷')

        spec = importlib.util.spec_from_file_location('windows_packager', ROOT / 'scripts/package-windows.py')
        packager = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(packager)
        unsafe = folder / 'unsafe'
        unsafe.mkdir()
        (unsafe / 'CON.txt').write_text('測試')
        rejects('拒絕 Windows 保留檔名', lambda: packager.inventory(unsafe), '檔名無效')
        (unsafe / 'CON.txt').unlink()
        (unsafe / 'tail.').write_text('測試')
        rejects('拒絕 Windows 結尾句點檔名', lambda: packager.inventory(unsafe), '檔名無效')

    if (ROOT / 'desktop/cmd/filmdevelop-desktop/resource_windows_amd64.syso').exists():
        raise AssertionError('Go 建置留下暫存資源檔')
    report = {'checks': checks, 'passed': True, 'windowsExecutionVerified': False}
    (build / 'installer-smoke.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f'Windows 封裝 Smoke 通過：{len(checks)} 項；未執行 Windows 程式。')


if __name__ == '__main__':
    main()
