#!/usr/bin/env python3
"""建置並驗證 Windows x64 免安裝 ZIP；NSIS 僅保留為舊流程相容選項。"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile

from windows_payload import PE, validate_gui, validate_payload
from windows_resources import ROOT, project_version
from release_audit import audit


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def copy(source, destination):
    if not source.is_file() or source.is_symlink():
        raise ValueError(f'缺少封裝來源，請重新建置：{source}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def copy_tree(source, destination):
    if not source.is_dir():
        raise ValueError(f'缺少封裝資料夾：{source}')
    for path in sorted(source.rglob('*')):
        if path.is_symlink():
            raise ValueError(f'封裝來源不可包含符號連結：{path}')
        if path.is_file() and not path.name.startswith(('._', '.DS_Store')) and not path.name.endswith('.bak'):
            copy(path, destination / path.relative_to(source))


def inventory(folder):
    entries = []
    names = set()
    for path in sorted(folder.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(folder)
        for part in relative.parts:
            if (re.search(r'[<>:"/\\|?*\x00-\x1f]', part) or part.endswith(('.', ' '))
                    or re.match(r'(?i)^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)', part)):
                raise ValueError(f'Windows 檔名無效：{relative}')
        key = relative.as_posix().casefold()
        if key in names:
            raise ValueError(f'Windows 檔名大小寫衝突：{relative}')
        names.add(key)
        entries.append({'path': relative.as_posix(), 'size': path.stat().st_size, 'sha256': digest(path)})
    return entries


def nsis_escape(value):
    value = str(value)
    if any(char in value for char in '\r\n\0'):
        raise ValueError('NSIS 路徑不可包含換行或 NUL')
    return value.replace('$', '$$').replace('"', '$\\"')


def payload_include(files, destination):
    paths = [Path(entry['path']) for entry in files]
    install = ['!macro InstallPayload']
    check = ['!macro CheckPayloadClosed']
    remove = ['!macro RemovePayloadFiles']
    last = None
    for index, path in enumerate(paths):
        relative = nsis_escape(str(path).replace('/', '\\'))
        parent = '' if path.parent == Path('.') else '\\' + nsis_escape(str(path.parent).replace('/', '\\'))
        if parent != last:
            install.append(f' SetOutPath "$INSTDIR{parent}"')
            last = parent
        install.append(f' File "${{PAYLOAD_DIR}}/{nsis_escape(path.as_posix())}"')
        check.append(f' !insertmacro CheckFileClosed "{relative}" "payload_{index}"')
        if path.name != '.filmdevelop-installed.ini':
            remove.append(f' Delete "$INSTDIR\\{relative}"')
    directories = sorted({parent for path in paths for parent in path.parents if parent != Path('.')},
                         key=lambda p: (-len(p.parts), str(p)))
    clean = ['!macro RemovePayloadDirectories']
    for directory in directories:
        relative = nsis_escape(str(directory).replace('/', '\\'))
        # 不遞迴刪除：保留使用者放入安裝目錄的其他檔案。
        clean.append(f' RMDir "$INSTDIR\\{relative}"')
    destination.write_text('\n\n'.join('\n'.join(lines + ['!macroend'])
                                        for lines in (install, check, remove, clean)) + '\n', encoding='utf-8')


def nsis_license(makensis):
    output = subprocess.check_output([makensis, '-HDRINFO'], text=True)
    match = re.search(r'(?:^|,)NSISDIR=([^,\r\n]+)', output)
    if not match:
        raise ValueError('無法取得 NSIS 授權位置')
    license_ = Path(match.group(1)) / 'COPYING'
    if not license_.is_file():
        raise ValueError(f'找不到 NSIS 授權：{license_}')
    return license_


def stage_payload(build, stage, info, makensis=None, portable=True):
    expected = json.loads((build / 'resources/build-info.json').read_text())
    if expected != info:
        raise ValueError('Windows 程式版本與目前專案不同；請移除 --no-build 後重試')
    gui = validate_gui(build / 'bin/FilmDevelopGo.exe', info, build / 'resources/FilmDevelop.exe.manifest')
    mapping = {
        'bin/FilmDevelopGo.exe': 'FilmDevelop.exe',
        # Windows 不區分大小寫，CLI 不可和 FilmDevelop.exe 共用名稱。
        'bin/filmdevelop.exe': 'filmdevelop-cli.exe',
        'bin/filmdevelop-update.exe': 'filmdevelop-update.exe',
        'core/libPhotoCompute.dll': 'engine/libPhotoCompute.dll',
        'core/photo_core_film.exe': 'engine/photo_core_film.exe',
        'core/film.comp.spv': 'engine/film.comp.spv',
        'native/filmdevelop-engine.exe': 'engine/filmdevelop-engine.exe',
        'native/neutral-recipe.json': 'engine/neutral-recipe.json',
        'native/style-catalog.json': 'engine/style-catalog.json',
    }
    for source, destination in mapping.items():
        copy(build / source, stage / destination)
    copy_tree(build / 'core/film-data', stage / 'engine/film-data')
    copy_tree(build / 'raw/RAWMapping', stage / 'engine/RAWMapping')
    copy_tree(build / 'raw/RAWLicenses', stage / 'Licenses/RAW')
    copy_tree(build / 'webp/WebPLicenses', stage / 'Licenses/WebP')
    copy_tree(build / 'vision/models', stage / 'engine/vision-models')
    copy_tree(build / 'vision/Licenses', stage / 'Licenses/Vision')
    copy_tree(build / 'neural/bin', stage / 'engine')
    copy_tree(build / 'neural/Licenses', stage / 'Licenses/Neural')
    for module in ('libllama.dll', 'libmtmd.dll', 'ggml.dll', 'ggml-base.dll', 'ggml-cpu.dll', 'ggml-vulkan.dll'):
        copy(build / 'llama/bin' / module, stage / 'engine' / module)
    copy_tree(build / 'llama/Licenses', stage / 'Licenses/LLM')
    copy(ROOT / 'PhotoStyleApp/Models/LaMa-LICENSE.txt', stage / 'Licenses/Repair/LaMa-Apache-2.0.txt')
    copy_tree(build / 'Licenses/Go', stage / 'Licenses/Go')
    copy(ROOT / 'experiments/PhotoCoreCpp/third_party/nlohmann/LICENSE', stage / 'Licenses/nlohmann-json.txt')
    copy_tree(ROOT / 'packaging/windows/licenses', stage / 'Licenses/Windows')
    if portable:
        copy_tree(build / 'vc-runtime/bin', stage / 'engine')
        copy_tree(build / 'vc-runtime/Licenses', stage / 'Licenses/Windows/VisualCpp')
    else:
        for name in ('ensure-prerequisites.ps1', 'prerequisites.json'):
            copy(ROOT / 'packaging/windows' / name, stage / 'Prerequisites' / name)
        copy(nsis_license(makensis), stage / 'Licenses/Windows/NSIS.txt')
    for name in ('LICENSE.md', 'LICENSE.en.md', 'LICENSE.ja.md', 'LICENSE.ko.md', 'THIRD_PARTY_NOTICES.md'):
        copy(ROOT / name, stage / name)
    readme_name = 'README.txt' if portable else 'README-installer.txt'
    readme = (ROOT / 'packaging/windows' / readme_name).read_text().replace('@DISPLAY_VERSION@', info['displayVersion'])
    (stage / 'README.txt').write_bytes(b'\xef\xbb\xbf' + readme.replace('\n', '\r\n').encode('utf-8'))
    if not portable:
        (stage / '.filmdevelop-installed.ini').write_bytes(
            b'[Install]\r\nProduct=person.vader.FilmDevelop.Windows\r\nArchitecture=x64\r\n')
    commit = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = bool(subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain']))
    metadata = dict(info, product='person.vader.FilmDevelop.Windows',
                    distribution='portable' if portable else 'installer',
                    gitCommit=commit, sourceTreeDirty=dirty,
                    builtAtUTC=datetime.now(timezone.utc).isoformat(),
                    windowsExecutionVerified=False, windowsGPUVerified=False)
    write_json(stage / 'build-info.json', metadata)
    files = inventory(stage)
    write_json(stage / 'files.json', {'schema': 1, 'algorithm': 'SHA-256', 'files': files})
    # files.json 不記錄自己的雜湊；外部報告再完整記錄整個安裝內容。
    return gui, validate_payload(stage), inventory(stage)


def portable_zip(stage, destination, files):
    # 固定一層產品目錄；只使用受驗證清單，不掃入舊安裝器、暫存檔或設定。
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for entry in files:
            archive.write(stage / entry['path'], 'FilmDevelop/' + entry['path'])
    with zipfile.ZipFile(destination) as archive:
        expected = {'FilmDevelop/' + entry['path']: entry for entry in files}
        if len(archive.infolist()) != len(expected) or set(archive.namelist()) != set(expected):
            raise ValueError('免安裝 ZIP 檔案清單不符')
        for item in archive.infolist():
            entry = expected[item.filename]
            checksum = hashlib.sha256()
            with archive.open(item) as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    checksum.update(block)
            if item.file_size != entry['size'] or checksum.hexdigest() != entry['sha256']:
                raise ValueError(f'免安裝 ZIP 解壓內容不符：{entry["path"]}')
    return {'archiveIntegrityPassed': True, 'payloadHashRoundTripPassed': True,
            'verifiedFileCount': len(files), 'payloadArchitecture': 'x64',
            'requiresProductInstallation': False, 'appLocalVCRuntime': True}


def verify_archive(sevenzip, setup, files, temporary):
    log = temporary / 'archive-check.log'
    unpacked = temporary / 'unpacked'
    with log.open('w') as stream:
        subprocess.run([sevenzip, 't', str(setup)], stdout=stream, stderr=subprocess.STDOUT, check=True)
        subprocess.run([sevenzip, 'x', '-y', f'-o{unpacked}', str(setup)],
                       stdout=stream, stderr=subprocess.STDOUT, check=True)
    for entry in files:
        path = unpacked / entry['path']
        if not path.is_file() or path.stat().st_size != entry['size'] or digest(path) != entry['sha256']:
            raise ValueError(f'安裝檔解壓內容不符：{entry["path"]}')
    expected = {entry['path'] for entry in files}
    # NSIS 會另外產生解除安裝程式與執行外掛，不能混入其他產品檔案。
    extras = {p.relative_to(unpacked).as_posix() for p in unpacked.rglob('*') if p.is_file()} - expected
    if any(name != 'Uninstall.exe' and not name.startswith('$PLUGINSDIR/') for name in extras):
        raise ValueError(f'安裝檔出現非預期內容：{sorted(extras)}')
    uninstaller = unpacked / 'Uninstall.exe'
    if not uninstaller.is_file():
        raise ValueError('安裝檔缺少解除安裝程式')
    # NSIS 預設使用 x86 啟動器，主程式與計算模組仍全部是 x64。
    setup_pe, uninstall_pe = PE(setup), PE(uninstaller)
    if setup_pe.machine != 0x14c or uninstall_pe.machine != 0x14c:
        raise ValueError('非預期的 NSIS 啟動器架構')
    version, flags, _ = setup_pe.version()
    if version != project_version()['numericVersion'] or flags != 0:
        raise ValueError('安裝程式版本不符')
    return {'archiveIntegrityPassed': True, 'payloadHashRoundTripPassed': True,
            'verifiedFileCount': len(files), 'uninstallerPresent': True,
            'installerStubArchitecture': 'x86', 'payloadArchitecture': 'x64'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--no-build', action='store_true', help='使用既有交叉編譯產物；仍檢查版本與完整性')
    parser.add_argument('--format', choices=('zip', 'installer'), default='zip',
                        help='預設免安裝 ZIP；installer 僅供舊流程相容')
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('WINDOWS_CROSS_BUILD_DIR', ROOT / 'build/windows-cross')))
    parser.add_argument('--output-dir', type=Path, default=ROOT / 'dist/windows-x64')
    args = parser.parse_args()
    makensis = shutil.which('makensis')
    sevenzip = shutil.which('7zz') or shutil.which('7z')
    if args.format == 'installer' and (not makensis or not sevenzip):
        raise ValueError('需要 NSIS（makensis）與 7-Zip（7zz 或 7z）')
    build, output = args.build_dir.resolve(), args.output_dir.resolve()
    if not args.no_build:
        subprocess.run(['bash', str(ROOT / 'scripts/build-windows-cross.sh')],
                       env=dict(os.environ, WINDOWS_CROSS_BUILD_DIR=str(build)), check=True)
    subprocess.run(['python3', str(ROOT / 'engine/verification/windows-installer-smoke.py'),
                    '--build-dir', str(build)], check=True)
    info = project_version()
    output.mkdir(parents=True, exist_ok=True)
    portable = args.format == 'zip'
    suffix = 'portable.zip' if portable else 'setup.exe'
    name = f'FilmDevelop-{info["version"]}-build{info["build"]}-windows-x64-{suffix}'
    # 同一檔案系統的暫存目錄：完整檢查通過後才以原子替換交付產物。
    with tempfile.TemporaryDirectory(prefix='.filmdevelop-package-', dir=output) as directory:
        temporary = Path(directory)
        stage = temporary / 'payload'
        stage.mkdir()
        gui, binaries, files = stage_payload(build, stage, info, makensis, portable)
        privacy = audit(stage)
        if portable:
            archive = temporary / name
            checks = portable_zip(stage, archive, files)
            report = dict(info, **checks, distribution='portable', guiResources=gui,
                          binaries=binaries, files=files, privacyAudit=privacy,
                          packagingSmoke=json.loads((build / 'installer-smoke.json').read_text()),
                          archive=name, archiveBytes=archive.stat().st_size, archiveSHA256=digest(archive),
                          crossCompilationPassed=True, windowsExecutionVerified=False,
                          windowsGPUVerified=False, authenticodeSigned=False, releasePublished=False)
            write_json(temporary / 'verification.json', report)
            (temporary / 'SHA256SUMS').write_text(f'{digest(archive)}  {name}\n', encoding='ascii')
            for filename in ('verification.json', 'SHA256SUMS', name):
                os.replace(temporary / filename, output / filename)
            print(f'Windows x64 免安裝 ZIP 已建立：{output / name}')
            print(f'已驗證 {len(files)} 個產品檔案、x64 相依、解壓雜湊與私密資料；尚未執行本次 ZIP 的實機測試。')
            return
        include = temporary / 'payload.nsh'
        payload_include(files, include)
        setup = temporary / name
        definitions = {
            'PAYLOAD_DIR': stage, 'PAYLOAD_INCLUDE': include,
            'OUTPUT_FILE': setup, 'ICON_FILE': build / 'resources/FilmDevelop.ico',
            'NUMERIC_VERSION': info['numericVersion'], 'DISPLAY_VERSION': info['displayVersion'],
            'INSTALLED_SIZE_KB': (sum(entry['size'] for entry in files) + 1023) // 1024 + 256,
        }
        with (temporary / 'nsis-build.log').open('w') as log:
            result = subprocess.run([makensis, '-V3', '-WX', *[f'-D{k}={nsis_escape(v)}' for k, v in definitions.items()],
                                     str(ROOT / 'packaging/windows/installer.nsi')], stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            print((temporary / 'nsis-build.log').read_text())
            raise ValueError('NSIS 編譯未通過；未覆蓋先前的安裝檔')
        checks = verify_archive(sevenzip, setup, files, temporary)
        report = dict(info, **checks, guiResources=gui, binaries=binaries, files=files,
                      packagingSmoke=json.loads((build / 'installer-smoke.json').read_text()),
                      installer=name, installerBytes=setup.stat().st_size, installerSHA256=digest(setup),
                      crossCompilationPassed=True, windowsExecutionVerified=False,
                      windowsInstallUninstallVerified=False, windowsGPUVerified=False,
                      authenticodeSigned=False, releasePublished=False, privacyAudit=privacy)
        write_json(temporary / 'verification.json', report)
        (temporary / 'SHA256SUMS').write_text(f'{digest(setup)}  {name}\n', encoding='ascii')
        for filename in ('verification.json', 'SHA256SUMS', 'nsis-build.log', 'archive-check.log', 'payload.nsh', name):
            os.replace(temporary / filename, output / filename)
    print(f'Windows x64 安裝檔已建立：{output / name}')
    print(f'安裝內容共 {len(files)} 個檔案，架構、靜態 DLL 相依與解壓雜湊檢查通過。')
    print('尚未執行 Windows 實機安裝／解除安裝與 GPU 測試；未發布 Release。')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Windows 封裝失敗：{error}')
