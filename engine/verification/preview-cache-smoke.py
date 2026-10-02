#!/usr/bin/env python3
"""驗證真實 Swift 預覽快取的重用、失效及獨立工作像素一致性。"""
import copy
import json
from pathlib import Path
import signal
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
worker = root/'build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine'
previous = json.loads((root/'build/engine-smoke-latest.json').read_text())
fixture = Path(previous['report']).parent/'來源照片.bmp'
out = Path(tempfile.mkdtemp(prefix='preview-cache-smoke-', dir=root/'build'))
source = out/'照片.bmp'
source.write_bytes(fixture.read_bytes())
catalog = json.loads(subprocess.check_output([str(root/'build/filmdevelop'), '-method', 'catalog']))
style = next(s for s in catalog['styles'] if s['id']=='filmPortra400')
job = {'input':{'path':str(source),'rawDecoder':'system','lensCorrection':True},
       'output':{'path':'','format':'jpeg','bitDepth':8,'colorSpace':'sRGB','quality':.88,'maxPixel':2048,'webPLossless':False,'tiffCompression':1},
       'recipe':{'version':1,'style':style['id'],'adjustment':style['adjustment'],'repairPatches':[],'detectSubject':False},
       'computeBackend':'system','preview':True,'previewMaxPixel':2048,
       'policy':{'highlightProtection':True,'modernExposure':False,'hdr':True,'fullResolution':False}}
session = subprocess.Popen([str(worker),'--preview-session'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(out/'stderr.log').open('w'), text=True)
signal.alarm(120)
results=[]
try:
    for name in ['cold','exposure','live','settled-again','live-again','crop','mask','mask-warm','same-path-changed','lens-setting']:
        current=copy.deepcopy(job)
        current['output']['path']=str(out/(name+'.jpg'))
        if name=='exposure': current['recipe']['adjustment']['exposure']=6
        if name in ('live','live-again'):
            current['previewMaxPixel']=1024
            current['output']['maxPixel']=1024
        if name=='crop': current['recipe']['adjustment']['cropAspectRatio']='oneOne'
        if name in ('mask','mask-warm'):
            current['recipe']['detectSubject']=True
            current['recipe']['adjustment']['skinSmoothing']=40
        if name=='same-path-changed':
            data=bytearray(source.read_bytes()); data[-12]^=127; source.write_bytes(data)
        if name=='lens-setting': current['input']['lensCorrection']=False
        request={'version':1,'id':name,'method':'preview','payload':current}
        session.stdin.write(json.dumps(request)+'\n');session.stdin.flush()
        while True:
            line=session.stdout.readline()
            assert line, '預覽程序提早退出'
            reply=json.loads(line)
            assert reply['id']==name and reply['version']==1
            if reply['kind']=='progress': continue
            assert reply['kind']=='result',reply
            result=reply['payload'];break
        timing=result['timing']
        assert timing['sourceCacheHit']==(name not in ['cold','same-path-changed','lens-setting']), (name,timing)
        if name=='exposure': assert timing['comparisonCacheHit']
        if name=='live': assert not timing['processingCacheHit']
        if name in ('settled-again','live-again'):
            assert timing['processingCacheHit'] and timing['comparisonCacheHit'], (name,timing)
        if name=='crop': assert not timing['comparisonCacheHit']
        if name=='mask': assert not timing['maskCacheHit']
        if name=='mask-warm': assert timing['maskCacheHit']
        assert result['sourceImage'].startswith('data:image/jpeg;base64,') and result['cropImage'].startswith('data:image/jpeg;base64,')
        # 同一配方另以無快取的 Swift 入口執行，確認快取未改變照片結果。
        direct=copy.deepcopy(request);direct['method']='render';direct['payload']['output']['path']=str(out/(name+'-reference.jpg'))
        check=subprocess.run([str(worker)],input=json.dumps(direct),capture_output=True,text=True,timeout=45,check=True)
        assert json.loads(check.stdout.splitlines()[-1])['kind']=='result'
        comparison=json.loads(subprocess.check_output([str(root/'build/engine-compare-images'),current['output']['path'],direct['payload']['output']['path']]))
        assert comparison['rmse']<.001 and comparison['maxError']<.02,(name,comparison)
        results.append({'case':name,'passed':True,'timing':timing,'pixelComparison':comparison})
finally:
    session.stdin.close()
    try: session.wait(timeout=10)
    except subprocess.TimeoutExpired: session.kill();session.wait();raise
    signal.alarm(0)
assert session.returncode==0
assert source.read_bytes()!=fixture.read_bytes()
(out/'report.json').write_text(json.dumps({'passed':True,'cases':results},ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'passed':True,'cases':len(results),'report':str(out/'report.json')},ensure_ascii=False))
