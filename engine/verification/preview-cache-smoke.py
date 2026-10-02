#!/usr/bin/env python3
"""驗證真實 Swift 預覽快取的重用、失效及獨立工作像素一致性。"""
import copy
import base64
import hashlib
import json
from pathlib import Path
import signal
import struct
import subprocess
import tempfile
import zlib

root = Path(__file__).resolve().parents[2]
worker = root/'build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine'
previous = json.loads((root/'build/engine-smoke-latest.json').read_text())
fixture = Path(previous['report']).parent/'來源照片.bmp'
out = Path(tempfile.mkdtemp(prefix='preview-cache-smoke-', dir=root/'build'))
source = out/'照片.bmp'
source.write_bytes(fixture.read_bytes())
def patch_png():
    def chunk(name, data):
        return struct.pack('>I', len(data)) + name + data + struct.pack('>I', zlib.crc32(name + data))
    data = b''.join(b'\0' + bytes([255, 128, 64]) * 8 for _ in range(8))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 8, 8, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(data)) + chunk(b'IEND', b'')
patch = {'id':'6BA7B810-9DAD-41D1-80B4-00C04FD430C8','x':.18,'y':.21,'width':.42,'height':.37,'linearGain':1.2,
         'imageData':base64.b64encode(patch_png()).decode(),'maskData':base64.b64encode(patch_png()).decode()}
catalog = json.loads(subprocess.check_output([str(root/'build/filmdevelop'), '-method', 'catalog']))
style = next(s for s in catalog['styles'] if s['id']=='filmPortra400')
job = {'input':{'path':str(source),'rawDecoder':'system','lensCorrection':True},
       'output':{'path':'','format':'jpeg','bitDepth':8,'colorSpace':'sRGB','quality':.88,'maxPixel':2048,'webPLossless':False,'tiffCompression':1},
       'recipe':{'version':1,'style':style['id'],'adjustment':style['adjustment'],'repairPatches':[],'detectSubject':False},
       'computeBackend':'system','preview':True,'previewMaxPixel':2048,
       'policy':{'highlightProtection':True,'modernExposure':False,'hdr':True,'fullResolution':False}}
session = subprocess.Popen([str(worker),'--preview-session'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(out/'stderr.log').open('w'), text=True)
signal.alarm(240)
results=[]
try:
    for name in ['cold','tone-brightness','tone-color','tone-hdr','tone-vignette','prefix-white-balance','prefix-grain','prefix-default','low-strength','low-strength-tone','monochrome','monochrome-tone','exposure','live','settled-again','live-again','crop','crop-rotation',
                 'crop-exposure','crop-exposure-warm','crop-policy','crop-backend','crop-full',
                 'crop-repair','crop-repair-warm','crop-repair-changed',
                 'mask','mask-warm','crop-saved-mask','crop-saved-mask-warm','crop-saved-mask-changed',
                 'same-path-changed','lens-setting']:
        current=copy.deepcopy(job)
        current['output']['path']=str(out/(name+'.jpg'))
        if name=='tone-brightness': current['recipe']['adjustment']['brightness']=65
        if name=='tone-color':
            current['recipe']['adjustment']['contrast']=20
            current['recipe']['adjustment']['saturation']=15
            current['recipe']['adjustment']['vibrance']=20
        if name=='tone-hdr': current['recipe']['adjustment']['hdrAmount']=45
        if name=='tone-vignette': current['recipe']['adjustment']['vignette']=30
        if name=='prefix-white-balance': current['recipe']['adjustment']['whiteBalanceWarmth']=30
        if name=='prefix-grain': current['recipe']['adjustment']['grain']=70
        if name.startswith('low-strength'):
            current['recipe']['adjustment']['intensity']=20
        if name.startswith('monochrome'):
            mono=next(s for s in catalog['styles'] if s['id']=='filmHP5')
            current['recipe']['style']=mono['id']
            current['recipe']['adjustment']=copy.deepcopy(mono['adjustment'])
        if name in ('low-strength-tone','monochrome-tone'):
            current['recipe']['adjustment']['brightness']=65
        if name=='exposure': current['recipe']['adjustment']['exposure']=6
        if name in ('live','live-again'):
            current['previewMaxPixel']=1024
            current['output']['maxPixel']=1024
        if name.startswith('crop'):
            current['recipe']['adjustment']['cropAspectRatio']='oneOne'
        if name=='crop-rotation': current['recipe']['adjustment']['cropRotation']=8
        if name in ('crop-exposure','crop-exposure-warm'): current['recipe']['adjustment']['exposure']=6
        if name=='crop-policy': current['policy']['highlightProtection']=False
        if name=='crop-backend': current['computeBackend']='vulkan'
        if name=='crop-full': current['policy']['fullResolution']=True
        if name.startswith('crop-repair'):
            current['recipe']['repairPatches']=[copy.deepcopy(patch)]
            if name=='crop-repair-changed': current['recipe']['repairPatches'][0]['linearGain']=.7
        if name.startswith('crop-saved-mask'):
            mask_path=out/'subject.mask.rgba'
            alpha=.4 if name=='crop-saved-mask-changed' else 1.
            data=b'FYPMASK1'+struct.pack('<II',8,8)+struct.pack('<ffff',alpha,alpha,alpha,1.)*64
            mask_path.write_bytes(data)
            current['recipe']['detectSubject']=True
            current['recipe']['adjustment']['skinSmoothing']=40
            current['subjectMask']={'path':str(mask_path),'sha256':hashlib.sha256(data).hexdigest()}
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
        if name.startswith('tone-') or name in ('low-strength-tone','monochrome-tone'): assert timing['stageCacheHits'] > 0, (name,timing)
        if name in ('cold','prefix-white-balance','prefix-grain','prefix-default','monochrome','exposure','live','crop-policy','crop-backend','crop-full','crop-repair','crop-repair-changed','crop-saved-mask-changed','same-path-changed','lens-setting'):
            assert timing['stageCacheHits'] == 0, (name,timing)
        if name=='low-strength-tone': assert timing['stageCacheHits'] == 2, (name,timing)
        if name=='exposure': assert timing['comparisonCacheHit']
        if name=='live': assert not timing['processingCacheHit']
        if name in ('settled-again','live-again'):
            assert timing['processingCacheHit'] and timing['comparisonCacheHit'], (name,timing)
        if name=='crop': assert not timing['comparisonCacheHit']
        if name.startswith('crop'):
            assert timing['editorCacheHit']==(name in ['crop','crop-rotation','crop-exposure-warm','crop-repair-warm','crop-saved-mask-warm']), (name,timing)
        if name=='mask': assert not timing['maskCacheHit']
        if name=='mask-warm': assert timing['maskCacheHit']
        assert result['sourceImage'].startswith('data:image/jpeg;base64,') and result['cropImage'].startswith('data:image/jpeg;base64,')
        # 同一配方另以無快取的 Swift 入口執行，確認快取未改變照片結果。
        direct=copy.deepcopy(request);direct['method']='render';direct['payload']['output']['path']=str(out/(name+'-reference.jpg'))
        check=subprocess.run([str(worker)],input=json.dumps(direct),capture_output=True,text=True,timeout=45,check=True)
        reference=json.loads(check.stdout.splitlines()[-1])
        assert reference['kind']=='result',reference
        comparison=json.loads(subprocess.check_output([str(root/'build/engine-compare-images'),current['output']['path'],direct['payload']['output']['path']]))
        assert comparison['rmse']<.001 and comparison['maxError']<.02,(name,comparison)
        # 未裁切編輯圖本身也必須與獨立顯影一致，不能只驗收裁切後主圖。
        for label, payload in [('editor',result),('editor-reference',reference['payload'])]:
            (out/(name+'-'+label+'.jpg')).write_bytes(base64.b64decode(payload['cropImage'].split(',',1)[1]))
        editor_comparison=json.loads(subprocess.check_output([str(root/'build/engine-compare-images'),str(out/(name+'-editor.jpg')),str(out/(name+'-editor-reference.jpg'))]))
        assert editor_comparison['rmse']<.001 and editor_comparison['maxError']<.02,(name,editor_comparison)
        results.append({'case':name,'passed':True,'timing':timing,'pixelComparison':comparison,'editorComparison':editor_comparison})
finally:
    session.stdin.close()
    try: session.wait(timeout=10)
    except subprocess.TimeoutExpired: session.kill();session.wait();raise
    signal.alarm(0)
assert session.returncode==0
assert source.read_bytes()!=fixture.read_bytes()
(out/'report.json').write_text(json.dumps({'passed':True,'cases':results},ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'passed':True,'cases':len(results),'report':str(out/'report.json')},ensure_ascii=False))
