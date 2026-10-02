#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/require-apple-silicon.sh"
/usr/bin/python3 "$ROOT_DIR/scripts/build-raw-dependencies.py" macos-arm64
/usr/bin/python3 - "$ROOT_DIR" <<'PY'
import concurrent.futures, fcntl, gzip, hashlib, json, os, pathlib, re, shutil, subprocess, sys, tarfile, urllib.request
root = pathlib.Path(sys.argv[1])
dependencies = json.loads((root / '.cache/photoraw-dependencies/macos-arm64/dependencies.json').read_text())
vendor = root / 'Vendor/PhotoRAW'
build = root / '.cache/photoraw-macos'
output = vendor / 'macos'
build.mkdir(parents=True, exist_ok=True)
with (build / 'build.lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    digest = hashlib.sha256()
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    clang = subprocess.check_output(['xcrun', '--find', 'clang++'], text=True).strip()
    digest.update((sdk + subprocess.check_output([clang, '--version'], text=True)).encode())
    digest.update((root / 'scripts/build-raw-dependencies.py').read_bytes())
    for library in dependencies['libraries']:
        digest.update(pathlib.Path(library).read_bytes())
    inputs = [root / 'scripts/build-raw-macos.sh'] + sorted(p for d in ('src', 'Mapping') for p in (vendor/d).rglob('*') if p.is_file() and not p.name.startswith('.') and not p.name.endswith('.bak'))
    for p in inputs:
        digest.update(str(p.relative_to(root)).encode()); digest.update(p.read_bytes())
    fingerprint = digest.hexdigest()
    archive = output / 'lib/libphotoraw.a'
    stamp = output / 'build.sha256'
    # macOS AppleDouble 附加資訊不是色彩對照表，不參與建置或快取檢查。
    mappings = {name: sha for name, sha in json.loads((vendor/'Mapping/sha256.json').read_text()).items()
                if not name.startswith('._')}
    expected = [output/'include/module.modulemap', output/'RAWMapping/index.tsv', output/'RAWLicenses/LICENSE.CDDL']
    expected += [output/'RAWMapping'/name for name in mappings]
    if archive.is_file() and stamp.is_file() and stamp.read_text().strip() == fingerprint and all(p.is_file() for p in expected):
        sys.exit(0)
    source_archive = build/'libraw-0.22.2.tar.gz'
    sha = '627928088300ecde6ca91ffd202e189203f04ad61ad12f0fe9dc57b9a7a0fb3c'
    if not source_archive.is_file() or hashlib.sha256(source_archive.read_bytes()).hexdigest() != sha:
        temporary = source_archive.with_suffix('.download')
        urllib.request.urlretrieve('https://codeload.github.com/LibRaw/LibRaw/tar.gz/refs/tags/0.22.2', temporary)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != sha:
            temporary.unlink(); raise SystemExit('LibRaw archive checksum mismatch')
        temporary.replace(source_archive)
    with tarfile.open(source_archive) as tar:
        for member in tar.getmembers():
            if not (member.isfile() or member.isdir()) or pathlib.Path(member.name).is_absolute() or '..' in pathlib.Path(member.name).parts:
                raise SystemExit('Unexpected LibRaw archive member')
        tar.extractall(build)
    source = build/'LibRaw-0.22.2'
    manifest = (source/'Makefile.am').read_text().split('lib_libraw_a_SOURCES =',1)[1].split('lib_libraw_r_a_CXXFLAGS',1)[0]
    sources = list(dict.fromkeys(source/p for p in re.findall(r'src/[A-Za-z0-9_/]+\.cpp',manifest)))
    if len(sources)<70: raise SystemExit('Unexpected LibRaw source manifest')
    sources.append(vendor/'src/PhotoRAW.cpp')
    objects = build/'objects'; objects.mkdir(exist_ok=True)
    print('Building CPU RAW decoder (LibRaw 0.22.2, arm64)…',flush=True)
    def compile_source(p):
        obj = objects/(hashlib.sha256(str(p).encode()).hexdigest()+'.o')
        subprocess.run([clang,'-arch','arm64','-isysroot',sdk,'-mmacosx-version-min=14.0','-std=c++17','-O3',
            '-DNDEBUG','-DLIBRAW_NODLL','-DLIBRAW_NOTHREADS','-DUSE_ZLIB','-DUSE_JPEG','-DUSE_JPEG8','-DUSE_X3FTOOLS',
            '-fno-fast-math','-ffp-contract=off','-fvisibility=hidden','-w','-I',str(source)] +
            [arg for include in dependencies['includes'] for arg in ('-I',include)] +
            ['-c',str(p),'-o',str(obj)],check=True)
        return obj
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        compiled = list(executor.map(compile_source,sources))
    archive.parent.mkdir(parents=True,exist_ok=True)
    temporary = archive.with_suffix('.a.new')
    subprocess.run(['xcrun','libtool','-static','-o',str(temporary)]+[str(p) for p in compiled]+dependencies['libraries'],check=True)
    temporary.replace(archive)
    (output/'include').mkdir(exist_ok=True)
    shutil.copyfile(vendor/'src/PhotoRAW.h',output/'include/PhotoRAW.h')
    (output/'include/module.modulemap').write_text('module PhotoRAW {\n header "PhotoRAW.h"\n link "photoraw"\n link "c++"\n link "z"\n export *\n}\n')
    (output/'RAWMapping').mkdir(exist_ok=True)
    for name,expected_sha in mappings.items():
        data=gzip.decompress((vendor/'Mapping'/(name+'.gz')).read_bytes())
        if hashlib.sha256(data).hexdigest()!=expected_sha: raise SystemExit('Mapping checksum mismatch: '+name)
        (output/'RAWMapping'/name).write_bytes(data)
    shutil.copyfile(vendor/'Mapping/index.tsv',output/'RAWMapping/index.tsv')
    (output/'RAWLicenses').mkdir(exist_ok=True)
    for name in ('COPYRIGHT','LICENSE.CDDL','LICENSE.LGPL'):
        shutil.copyfile(source/name,output/'RAWLicenses'/name)
    for item in dependencies['licenses']:
        shutil.copyfile(item['source'],output/'RAWLicenses'/item['name'])
    x3f=(source/'src/x3f/x3f_utils_patched.cpp').read_text().split('/*',1)[1].split('*/',1)[0]
    (output/'RAWLicenses/X3F-LICENSE.txt').write_text(x3f.strip()+'\n')
    (output/'RAWLicenses/DEPENDENCIES.json').write_text(json.dumps(dependencies['sources'],indent=2)+'\n')
    (output/'RAWLicenses/SOURCE.txt').write_text('LibRaw 0.22.2, distributed under CDDL 1.0.\nUnmodified source: https://github.com/LibRaw/LibRaw/tree/0.22.2\nArchive: https://codeload.github.com/LibRaw/LibRaw/tar.gz/refs/tags/0.22.2\nSHA256: '+sha+'\nEnabled: zlib, JPEG DNG, X3F. Built without OpenMP, RawSpeed, DNG SDK, GPR SDK or additional demosaic packs.\n')
    stamp.write_text(fingerprint+'\n')
    print('Built '+str(archive),flush=True)
PY
