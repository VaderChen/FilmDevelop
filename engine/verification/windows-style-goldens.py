#!/usr/bin/env python3
"""使用現有 Swift 引擎產生 Windows 配方比對金樣本；需先建置 macOS 引擎。"""
import json,subprocess,time,hashlib,base64,math,struct,zlib
from pathlib import Path
root=Path(__file__).resolve().parents[2];out=root/'build/windows-style-goldens';out.mkdir(parents=True,exist_ok=True)
catalog=json.load(open(root/'desktop/internal/recipes/catalog.json'))
engine=root/'build/engine-macos/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine'
subprocess.run(['sips','-Z','320',str(root/'images/test.jpg'),'-s','format','png','--out',str(out/'input.png')],check=True,stdout=subprocess.DEVNULL)
import copy
base={s['id']:s for s in catalog['styles']}
for id in ['filmEktachrome100','filmHP5','gr3-negative']:
 for intensity in [0,25,100]:
  case=copy.deepcopy(base[id]);case['case']=id+'-strength-'+str(intensity);case['adjustment']['intensity']=intensity;catalog['styles'].append(case)
# 高曝光、負值與白平衡不可被數位色彩表截成 0...1。
looks=json.loads((root/'experiments/PhotoCoreCpp/data/digital-looks/manifest.json').read_text())['styles']
for style in looks:
 for name,parameters in [('high-exposure',{'exposure':100}),('low-exposure',{'exposure':-100}),('high-white-balance',{'exposure':75,'whiteBalanceWarmth':100,'whiteBalanceTint':-100}),('maximum-exposure',{'intensity':100,'exposure':100,'whiteBalanceWarmth':100,'whiteBalanceTint':-100})]:
  case=copy.deepcopy(base[style['id']]);case['case']=style['id']+'-'+name;case['adjustment'].update(parameters);catalog['styles'].append(case)
(out/'cases.json').write_text(json.dumps(catalog,ensure_ascii=False))
# 使用真實 Swift 管線覆蓋獨立控制及複合順序，避免只驗證預設配方。
edits = {
 'skin-white': {'skinWhitening':85},
 'skin-smooth': {'skinSmoothing':80},
 'skin-warm': {'skinWarmth':65},
 'skin-combined': {'skinWhitening':60,'skinSmoothing':75,'skinWarmth':-40,'whiteBalanceWarmth':30,'exposure':25},
 'crop-square': {'cropAspectRatio':'oneOne','cropScale':80,'cropHorizontalPosition':24,'cropVerticalPosition':-36},
 'crop-free': {'cropAspectRatio':'free','cropWidth':74,'cropHeight':62,'cropHorizontalPosition':-31,'cropVerticalPosition':28},
 'crop-rotate': {'cropAspectRatio':'threeTwo','cropRotation':13.5,'cropScale':76},
 'tone-zones': {'shadowIntensity':65,'midtoneIntensity':43,'highlightIntensity':85,'shadowWarmth':-24,'midtoneWarmth':31,'highlightWarmth':40},
 'white-balance': {'whiteBalanceWarmth': 63, 'whiteBalanceTint': -47},
 'white-balance-cool': {'whiteBalanceWarmth': -58, 'whiteBalanceTint': 31},
 'exposure-up': {'exposure': 35}, 'exposure-down': {'exposure': -70},
 'zone-exposure': {'highlightExposure': -25, 'midtoneExposure': 30, 'shadowExposure': 65},
 'lab-muted': {'vibrance': 70, 'saturation': -25}, 'lab-strong': {'vibrance': -55, 'saturation': 60},
 'digital-print': {'filmEffects':{'print_contrast':73,'print_illuminant':'tungsten2856','view_illuminant':'blackbody6500'}},
 'monochrome-filter': {'filmEffects':{'monochrome_filter':'orange','monochrome_filter_strength':70}},
 'vignette': {'vignette':85},
 'devignette': {'devignette': 80},
 'combined-color-hdr': {'contrast': 30, 'brightness': 60, 'vibrance': 40, 'saturation': 30, 'exposure': 20, 'hdrAmount': 45},
}
for frame in ['whitePaperThin','whitePaperWide','whitePaperPolaroid','blackLine','filmStrip','cleanInset']:
 edits['frame-'+frame]={'frameEnabled':True,'frameStyle':frame}
for field, value in [('base_tone', 72), ('tint', -85), ('contrast', 65), ('highlights', 75), ('shadows', -60), ('fade', 70), ('softness', 55)]:
 edits['plan-'+field]={'sourceToneZones':{'shadows':{field:value},'midtones':{field:-value if field in ['tint','contrast','shadows'] else value//2},'highlights':{field:value//3}}}
edits['plan-combined']={'sourceToneZones':{'shadows':{'base_tone':35,'tint':60,'contrast':-30,'shadows':40,'fade':25,'softness':30},'midtones':{'base_tone':-25,'tint':-20,'contrast':15,'highlights':35,'softness':18},'highlights':{'contrast':-45,'highlights':60,'fade':16}}}
for parameters in edits.values():
 if 'sourceToneZones' in parameters:
  for region in ['shadows','midtones','highlights']:
   fields={key:0 for key in ['base_tone','exposure','contrast','softness','grain','highlights','shadows','fade','warmth','tint','mapping']}
   fields.update(parameters['sourceToneZones'].get(region,{}));parameters['sourceToneZones'][region]=fields
for stage in ['input', 'output']:
 edits['calibration-'+stage]={'colorCalibration': {'version':1,'name':'跨平台校色比對','provenance':'Swift 參考輸出','workingSpace':'extendedLinearSRGB','stage':stage,'rows':[[1.04,0,0,-.025,0,0],[0,.98,0,.015,0,0],[0,0,1.02,0,-.015,0]]}}
for id in ['original','filmEktachrome100','gr3-negative','fujiClassicChrome','japaneseBWSoft']:
 for name, parameters in edits.items():
  case=copy.deepcopy(base[id]);case['case']=id+'-edit-'+name;case['adjustment'].update({k:v for k,v in parameters.items() if k!='filmEffects'});case['adjustment']['filmEffects'].update(parameters.get('filmEffects',{}));catalog['styles'].append(case)
# 保存貼片使用原始照片座標；分別驗證一般顯影與裁切旋轉後的結果。
fixtures=out/'fixtures';fixtures.mkdir(exist_ok=True)
def fixture(name,w,h,channels,values,linear):
 raw=bytes(values)
 def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
 scan=b''.join(b'\0'+raw[y*w*channels:(y+1)*w*channels] for y in range(h))
 png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2 if channels==3 else 0,0,0,0))+chunk(b'IDAT',zlib.compress(scan))+chunk(b'IEND',b'')
 (fixtures/(name+'.png')).write_bytes(png)
 pixels=[]
 for y in range(h-1,-1,-1):
  for x in range(w):
   for c in range(3):
    v=raw[(y*w+x)*channels+(c if channels==3 else 0)]/255
    pixels.append(v if linear else (v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4))
 (fixtures/(name+'.pfm')).write_bytes(('PF\n%d %d\n-1.0\n'%(w,h)).encode()+struct.pack('<%df'%len(pixels),*pixels))
 return base64.b64encode(png).decode()
color=fixture('repair-color',64,48,3,[v for y in range(48) for x in range(64) for v in (60+x,100+y,40+x//2)],False)
mask=fixture('repair-mask',64,48,1,[round(255*max(0,min(1,(1-math.hypot((x-31.5)/31.5,(y-23.5)/23.5))*4))) for y in range(48) for x in range(64)],True)
patch={'id':'6BA7B810-9DAD-41D1-80B4-00C04FD430C8','x':.18,'y':.21,'width':.42,'height':.37,'linearGain':1.2,'imageData':color,'maskData':mask}
for id in ['original','filmEktachrome100','gr3-negative']:
 for rotated in [False,True]:
  case=copy.deepcopy(base[id]);case['case']=id+'-repair'+('-rotated' if rotated else '');case['repairPatches']=[patch];case['patchPixels']=[{'image':'fixtures/repair-color.pfm','mask':'fixtures/repair-mask.pfm'}]
  if rotated:case['adjustment'].update({'cropAspectRatio':'oneOne','cropRotation':-17,'cropScale':84})
  catalog['styles'].append(case)
(out/'cases.json').write_text(json.dumps(catalog,ensure_ascii=False))
report=[]
for style in catalog['styles']:
 path=out/(style.get('case',style['id'])+'.png')
 if path.exists():path.unlink()
 job={'input':{'path':str(out/'input.png'),'rawDecoder':'system','lensCorrection':True},'output':{'path':str(path),'format':'png','bitDepth':16,'colorSpace':'sRGB','quality':.95,'maxPixel':0,'webPLossless':False,'tiffCompression':1},'recipe':{'version':1,'style':style['id'],'adjustment':style['adjustment'],'repairPatches':style.get('repairPatches',[]),'detectSubject':False},'computeBackend':'system','preview':True,'previewMaxPixel':320,'policy':{'highlightProtection':True,'modernExposure':False,'hdr':True,'fullResolution':False}}
 packet={'id':style['id'],'version':1,'method':'preview','payload':job}
 start=time.monotonic();p=subprocess.run([str(engine)],input=json.dumps(packet)+'\n',text=True,capture_output=True,timeout=120)
 replies=[json.loads(l) for l in p.stdout.splitlines() if l.startswith('{')]
 result=replies[-1] if replies else {'error':p.stderr}
 item={'style':style.get('case',style['id']),'passed':result.get('kind')=='result','seconds':time.monotonic()-start,'error':result.get('error')}
 report.append(item);print(json.dumps(item,ensure_ascii=False),flush=True)
 (out/'swift-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))

assert all(item['passed'] for item in report), 'Swift 金樣本未全部完成'
subprocess.run(['swift',str(root/'engine/verification/png-to-pfm.swift'),*[str(p) for p in out.glob('*.png') if p.name!='input.png']],check=True)
subprocess.run(['swift',str(root/'engine/verification/png-to-pfm.swift'),'--source',str(out/'input.png')],check=True)
(out/'reference-manifest.json').write_text(json.dumps({'engineSHA256':hashlib.sha256(engine.read_bytes()).hexdigest(),'inputSHA256':hashlib.sha256((out/'input.png').read_bytes()).hexdigest(),'casesSHA256':hashlib.sha256((out/'cases.json').read_bytes()).hexdigest(),'count':len(report)},indent=2)+'\n')
print('Swift 配方金樣本完成：',len(report))
