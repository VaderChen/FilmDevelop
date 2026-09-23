#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/require-apple-silicon.sh"
# Only the Xcode toolchain is required. The app links this archive statically;
# neither Homebrew nor an external encoder is used at runtime.
/usr/bin/python3 - "$ROOT_DIR" <<'PY'
import concurrent.futures, fcntl, hashlib, os, pathlib, shutil, subprocess, sys

root = pathlib.Path(sys.argv[1])
source = root / 'aiTest/ThirdParty/stable-diffusion.cpp/thirdparty/libwebp'
output = root / 'Vendor/libwebp/macos'
build = pathlib.Path(os.environ.get('WEBP_BUILD_DIR', str(root / '.cache/libwebp-macos')))
build.mkdir(parents=True, exist_ok=True)
with (build / 'build.lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    if not (source / 'src/webp/encode.h').is_file():
        raise SystemExit('Missing vendored libwebp source: ' + str(source))
    directories = [source / 'src' / part for part in ('dec', 'dsp', 'enc', 'utils')] + [source / 'sharpyuv']
    sources = sorted(p for directory in directories for p in directory.glob('*.c') if not p.name.startswith('.'))
    headers = sorted(p for directory in (source / 'src', source / 'sharpyuv') for p in directory.rglob('*.h') if not p.name.startswith('.'))
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    clang = subprocess.check_output(['xcrun', '--find', 'clang'], text=True).strip()
    digest = hashlib.sha256()
    digest.update(b'arm64;macos=14.0;static\n')
    digest.update((sdk + subprocess.check_output([clang, '--version'], text=True)).encode())
    for path in sources + headers + [root / 'scripts/build-webp-macos.sh', source / 'COPYING', source / 'PATENTS', source / 'AUTHORS']:
        digest.update(str(path.relative_to(root)).encode())
        digest.update(path.read_bytes())
    fingerprint = digest.hexdigest()
    archive = output / 'lib/libphotowebp.a'
    stamp = output / 'build.sha256'
    public_headers = [p for p in (source / 'src/webp').glob('*.h') if not p.name.startswith('.')]
    expected_files = [output / 'include/module.modulemap'] + [output / 'include/webp' / p.name for p in public_headers] + [output / 'WebPLicenses' / name for name in ('COPYING', 'PATENTS', 'AUTHORS')]
    if (archive.is_file() and stamp.is_file() and stamp.read_text().strip() == fingerprint
            and all(p.is_file() for p in expected_files)
            and subprocess.check_output(['xcrun', 'lipo', '-archs', str(archive)], text=True).strip() == 'arm64'):
        sys.exit(0)
    print('Building Apple Silicon static libwebp (arm64)…', flush=True)
    workers = max(1, min(16, int(os.environ.get('BUILD_JOBS', '8'))))
    objects = build / 'arm64'
    objects.mkdir(parents=True, exist_ok=True)
    def compile_source(path):
        object_path = objects / (str(path.relative_to(source)).replace('/', '_') + '.o')
        command = [clang, '-arch', 'arm64', '-isysroot', sdk, '-mmacosx-version-min=14.0',
                   '-std=c99', '-O3', '-DNDEBUG', '-DWEBP_USE_THREAD=1', '-fvisibility=hidden',
                   '-I', str(source), '-I', str(source / 'src'), '-c', str(path), '-o', str(object_path)]
        subprocess.run(command, check=True)
        return object_path
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        compiled = list(executor.map(compile_source, sources))
    (output / 'lib').mkdir(parents=True, exist_ok=True)
    temporary = output / 'lib/libphotowebp.a.new'
    subprocess.run(['xcrun', 'libtool', '-static', '-o', str(temporary)] + [str(p) for p in compiled], check=True)
    if subprocess.check_output(['xcrun', 'lipo', '-archs', str(temporary)], text=True).strip() != 'arm64':
        raise SystemExit('libwebp archive must contain only arm64')
    os.replace(temporary, archive)
    (output / 'include/webp').mkdir(parents=True, exist_ok=True)
    for header in (source / 'src/webp').glob('*.h'):
        if not header.name.startswith('.'):
            shutil.copyfile(header, output / 'include/webp' / header.name)
    (output / 'include/module.modulemap').write_text('module PhotoWebP {\n  header "webp/encode.h"\n  header "webp/decode.h"\n  link "photowebp"\n  export *\n}\n')
    (output / 'WebPLicenses').mkdir(exist_ok=True)
    for name in ('COPYING', 'PATENTS', 'AUTHORS'):
        shutil.copyfile(source / name, output / 'WebPLicenses' / name)
    stamp.write_text(fingerprint + '\n')
    print('Built ' + str(archive), flush=True)
PY
