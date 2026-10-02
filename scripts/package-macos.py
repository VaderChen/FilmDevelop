#!/usr/bin/env python3
"""封裝 Apple Silicon 混合 DMG；正式封裝必須完成 Developer ID 簽章與 Apple 公證。"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
from windows_resources import ROOT, project_version


def run(*args, capture=False):
    return subprocess.run(list(map(str,args)),check=True,text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def sign_app(app, identity):
    magic = {bytes.fromhex(value) for value in ('cffaedfe','cefaedfe','feedfacf','feedface','cafebabe','bebafeca','cafebabf','bfbafeca')}
    paths = sorted(app.rglob('*'),key=lambda path:len(path.parts),reverse=True)
    for path in paths:
        if path.is_symlink():
            continue
        if path.is_file():
            with path.open('rb') as file:
                executable = file.read(4) in magic
            if executable:
                run('codesign','--force','--timestamp','--options','runtime','--sign',identity,path)
        elif path.suffix in ('.app','.framework','.xpc','.bundle'):
            # 資源 bundle 沒有可執行檔，也一併封存簽章，避免外層簽署後再變更。
            run('codesign','--force','--timestamp','--options','runtime','--sign',identity,path)
    run('codesign','--force','--timestamp','--options','runtime','--sign',identity,app)
    run('codesign','--verify','--deep','--strict',app)


def notarize(path, profile, log):
    output = run('xcrun','notarytool','submit',path,'--keychain-profile',profile,
                 '--no-s3-acceleration','--output-format','json',capture=True)
    log.with_name(log.stem+'-submit.json').write_text(output)
    submission = json.loads(output)['id']
    output = run('xcrun','notarytool','wait',submission,'--keychain-profile',profile,
                 '--timeout','30m','--output-format','json',capture=True)
    log.write_text(output)
    result = json.loads(output)
    if result.get('status') != 'Accepted':
        run('xcrun','notarytool','log',submission,'--keychain-profile',profile,
            log.with_name(log.stem+'-issues.json'))
        raise ValueError(f"Apple 公證失敗：{result.get('status')}，提交 ID {result.get('id')}")


def staple(path):
    for attempt in range(10):
        result = subprocess.run(['xcrun','stapler','staple',str(path)],capture_output=True,text=True)
        if result.returncode == 0:
            run('xcrun','stapler','validate',path)
            return
        if attempt < 9:
            time.sleep(6)
    raise ValueError(f'Apple 公證票證附加失敗：{path.name}\n{result.stderr}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity',help='正式發布使用的 Developer ID Application 名稱或雜湊')
    parser.add_argument('--notary-profile',help='已儲存在本機 Keychain 的 notarytool 設定名稱')
    args = parser.parse_args()
    if bool(args.identity) != bool(args.notary_profile) or args.identity == '-':
        parser.error('正式封裝需同時指定 Developer ID --identity 及 --notary-profile')
    if args.notary_profile:
        run('xcrun','notarytool','history','--keychain-profile',args.notary_profile,
            '--output-format','json',capture=True)
    version = project_version()
    app = ROOT/'build/desktop/FilmDevelopGo.app'
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    assert info['CFBundleExecutable'] == 'FilmDevelopGo'
    assert info['CFBundleShortVersionString'] == version['version'] and info['CFBundleVersion'] == version['build']
    assert (app/'Contents/Resources/Engine/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine').is_file()
    run('codesign','--verify','--deep','--strict',app)
    destination = ROOT/'dist/macos-arm64'
    destination.mkdir(parents=True,exist_ok=True)
    name = f"FilmDevelop-{version['version']}-build{version['build']}-macos-arm64.dmg"
    with tempfile.TemporaryDirectory(prefix='filmdevelop-package-',dir=ROOT/'build') as temporary:
        work = Path(temporary)
        payload = work/'payload'
        payload.mkdir()
        staged = payload/'FilmDevelop.app'
        run('ditto',app,staged)
        if args.identity:
            sign_app(staged,args.identity)
            archive = work/'notarize.zip'
            run('ditto','-c','-k','--sequesterRsrc','--keepParent',staged,archive)
            notarize(archive,args.notary_profile,destination/'notary-app.json')
            staple(staged)
            run('spctl','--assess','--type','execute','--verbose=2',staged)
        (payload/'Applications').symlink_to('/Applications',target_is_directory=True)
        output = work/name
        run('hdiutil','create','-volname','FilmDevelop','-srcfolder',payload,'-format','UDZO',output)
        if args.identity:
            run('codesign','--force','--timestamp','--sign',args.identity,output)
            notarize(output,args.notary_profile,destination/'notary-dmg.json')
            staple(output)
            run('spctl','--assess','--type','open','--context','context:primary-signature','--verbose=2',output)
        run('hdiutil','verify',output)
        output.replace(destination/name)
    digest = hashlib.sha256()
    with (destination/name).open('rb') as file:
        for block in iter(lambda:file.read(1024*1024),b''):
            digest.update(block)
    (destination/'SHA256SUMS').write_text(f'{digest.hexdigest()}  {name}\n')
    (destination/'verification.json').write_text(json.dumps({
        'version':version['version'],'build':version['build'],'asset':name,
        'sha256':digest.hexdigest(),'developerIDSigned':bool(args.identity),
        'appleNotarized':bool(args.notary_profile),'stapled':bool(args.notary_profile)
    },ensure_ascii=False,indent=2)+'\n')
    print(destination/name)


if __name__ == '__main__':
    main()
