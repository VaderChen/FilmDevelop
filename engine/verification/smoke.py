#!/usr/bin/env python3
"""驗證 Go／原生契約、既有配方保留、真實渲染和錯誤發布邊界。"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--engine', type=Path, default=root/'build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine')
args = parser.parse_args()
worker = args.engine.resolve()
cli = root/'build/filmdevelop'
subprocess.run(['go','-C',str(root/'desktop'),'build','-o',str(cli),'./cmd/filmdevelop'],check=True)
run = Path(tempfile.mkdtemp(prefix='engine-smoke-',dir=root/'build'))
results = []
comparator = root/'build/engine-compare-images'
subprocess.run(['xcrun','swiftc',str(root/'engine/verification/compare-images.swift'),'-o',str(comparator)],check=True)

def native(method, payload):
    request={'version':1,'id':'smoke','method':method,'payload':payload}
    p=subprocess.run([str(worker)],input=json.dumps(request),capture_output=True,text=True,timeout=90)
    replies=[json.loads(line) for line in p.stdout.splitlines()]
    assert replies and replies[-1]['kind']=='result', (p.stderr,replies[-1:] or p.stdout)
    assert p.returncode==0
    assert all(r['id']=='smoke' and r['version']==1 for r in replies)
    return replies[-1]['payload']

def host(method, payload):
    path=run/'host-request.json';path.write_text(json.dumps(payload))
    return json.loads(subprocess.check_output([str(cli),'-engine',str(worker),'-method',method,'-request',str(path)],text=True))

catalog=host('catalog',None)
reference_catalog=json.loads((root/'desktop/internal/recipes/catalog.json').read_text())
assert {s['id'] for s in catalog['styles']}=={s['id'] for s in reference_catalog['styles']}
recipes={s['id']:{'version':1,'style':s['id'],'adjustment':s['adjustment'],'repairPatches':[],'detectSubject':False} for s in catalog['styles']}
for name, recipe in recipes.items():
    assert host('normalizeRecipe',recipe)==recipe, name
results.append({'case':f"{len(recipes)} 個預設與相容配方往返",'passed':True})
# 同一份實際配方經由 Go → C++ → Go 往返；不將序列化冒充 C++ 渲染。
subprocess.run(['cmake','-S',str(root/'engine/cpp'),'-B',str(root/'build/engine-contract-macos'),'-G','Ninja'],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['cmake','--build',str(root/'build/engine-contract-macos')],check=True,stdout=subprocess.DEVNULL)
fixture=run/'recipe-fixture.json';fixture.write_text(json.dumps(recipes['filmPortra400']))
response=subprocess.check_output([str(cli),'-native','-engine',str(root/'build/engine-contract-macos/filmdevelop-contract-smoke'),'-method','normalizeRecipe','-request',str(fixture)],text=True)
assert json.loads(response)==recipes['filmPortra400']
results.append({'case':'實際配方 Go／C++ 契約往返','passed':True})

# 非對稱、非正方形來源可暴露方向、裁切及通道錯誤。
w,h=97,65
stride=(w*3+3)//4*4
pixels=bytearray()
for y in range(h):
    row=b''.join(bytes(((x*7+y*3)%256,(y*11+x)%256,(x*3+y*5)%256)) for x in range(w))
    pixels.extend(row+b'\0'*(stride-len(row)))
bmp=b'BM'+struct.pack('<IHHI',54+len(pixels),0,0,54)+struct.pack('<IiiHHIIiiII',40,w,h,1,24,0,len(pixels),2835,2835,0,0)+pixels
source=run/'來源照片.bmp';source.write_bytes(bmp)
original_hash=hashlib.sha256(bmp).hexdigest()

def make_job(recipe,path,backend='system',fmt='png',depth=16):
    return {'input':{'path':str(source),'rawDecoder':'system','lensCorrection':True},
      'output':{'path':str(path),'format':fmt,'bitDepth':depth,'colorSpace':'sRGB','quality':.95,'maxPixel':0,'webPLossless':False,'tiffCompression':1},
      'recipe':recipe,'computeBackend':backend,'preview':False,'previewMaxPixel':1024}

def go_job(job,name,success=True):
    path=run/(name+'.json');path.write_text(json.dumps(job))
    p=subprocess.run([str(cli),'-engine',str(worker),'-method','render','-request',str(path)],capture_output=True,text=True,timeout=90)
    assert (p.returncode==0)==success, (name,p.stdout,p.stderr)
    return p

variants=[('original',recipes['original'],'system','png',16),('portra',recipes['filmPortra400'],'system','png',16),
          ('vulkan',recipes['filmPortra400'],'vulkan','png',16),('bw',recipes['filmHP5'],'system','png',16),
          ('hidden-camera',recipes['gr3-sky-orange'],'system','png',16)]
edited=host('editRecipe',{'recipe':recipes['filmPortra400'],'changes':[
    {'key':'exposure','value':12},{'key':'hdrAmount','value':20},
    {'cropValues':{'cropAspectRatio':'oneOne','cropRotation':8,'cropScale':80}},
    {'key':'developerContrast','value':1.2},{'key':'printExposure','value':3}]})
assert edited['adjustment']['exposure']==12 and edited['adjustment']['hdrToneCurve'] is not None
tone=host('editRecipe',{'recipe':recipes['original'],'changes':[{'key':'shadowPlanBaseTone','value':15.5}]})
assert tone['adjustment']['sourceToneZones']['shadows']['base_tone']==16
assert host('projectRecipes',{'original':tone})['original']['sourceToneZones']['shadows']['baseTone']==16
results.append({'case':'共用驗證與分區配方語意','passed':True})
variants.append(('composite',edited,'system','png',16))
for fmt,depth in [('jpeg',8),('webp',8),('tiff',16),('png',8)]:
    variants.append((fmt,recipes['original'],'system',fmt,depth))
for name,recipe,backend,fmt,depth in variants:
    job=make_job(recipe,run/(name+'-go.'+fmt),backend,fmt,depth)
    p=go_job(job,name)
    direct=copy.deepcopy(job);direct['output']['path']=str(run/(name+'-native.'+fmt))
    expected=native('render',direct)
    actual=json.loads(p.stdout)
    assert actual.pop('bytes')==Path(job['output']['path']).stat().st_size
    assert expected.pop('bytes')==Path(direct['output']['path']).stat().st_size
    assert actual==expected, (name,actual,expected)
    comparison=json.loads(subprocess.check_output([str(comparator),job['output']['path'],direct['output']['path']]))
    # 相同原生 GPU 路徑的獨立程序在浮點量化邊界可差 1 階；不容許可見像素漂移。
    tolerance=2/65535 if depth==16 else 1/255
    assert comparison['maxError']<=tolerance, (name,comparison)
    results.append({'case':name,'passed':True,'pixelComparison':comparison,'tolerance':tolerance,
                    'byteIdentical':Path(job['output']['path']).read_bytes()==Path(direct['output']['path']).read_bytes()})

for key,value in [('version',99),('unknownAdjustment',1)]:
    recipe=copy.deepcopy(recipes['original'])
    if key=='version': recipe['version']=value
    else: recipe['adjustment'][key]=value
    target=run/(key+'.png');go_job(make_job(recipe,target),key,False);assert not target.exists()
    results.append({'case':'拒絕 '+key,'passed':True})
target=run/'existing.png';target.write_bytes('不可覆蓋'.encode())
go_job(make_job(recipes['original'],target),'existing',False);assert target.read_bytes()=='不可覆蓋'.encode()
assert hashlib.sha256(source.read_bytes()).hexdigest()==original_hash
assert not list(run.glob('.filmdevelop-work-*'))
results.append({'case':'原圖、既有成品及暫存生命週期','passed':True})
report={'passed':True,'scope':'Go 宿主與直接 Swift 完整入口的像素一致性；非 Windows 演算法驗收','cases':results}
(run/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'passed':True,'cases':len(results),'report':str(run/'report.json')},ensure_ascii=False))
