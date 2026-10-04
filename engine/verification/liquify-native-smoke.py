#!/usr/bin/env python3
"""重跑正式液化幾何的 C++／Core Image Metal 像素與輸入驗證 Smoke。"""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=ROOT/'build/liquify-integration-smoke/native')
parser.add_argument('--windows-build', action='store_true', help='另以既有 CMake Windows 工具鏈建置正式原生引擎；不代表 Windows 實機執行。')
args = parser.parse_args()
OUT = args.output.resolve()
OUT.mkdir(parents=True, exist_ok=True)
commands = []

def run(command, **options):
    started = time.perf_counter()
    result = subprocess.run([str(v) for v in command], cwd=ROOT, capture_output=True, text=True, **options)
    commands.append({'command': [str(v) for v in command], 'returncode': result.returncode, 'seconds': round(time.perf_counter()-started, 3)})
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result

SWIFT_SOURCE = r'''
import Foundation
import CoreImage
@main struct Smoke {
 static func main() {
  do { try run() } catch { FileHandle.standardError.write(Data("液化測試拒絕輸入：\(error)\n".utf8)); exit(1) }
 }
 static func run() throws {
  let meshData=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
  let mesh=try JSONDecoder().decode(PhotoLiquifyMesh?.self,from:meshData)
  let width=Int(CommandLine.arguments[2])!,height=Int(CommandLine.arguments[3])!
  var pixels=[Float](repeating:0,count:width*height*4)
  for y in 0..<height {for x in 0..<width {
   let i=(y*width+x)*4,a:Float=x%13==0 ? 0 : (y%7==0 ? 0.35 : 1)
   pixels[i]=Float(x)/Float(width-1)*4*a;pixels[i+1]=(Float(y)/Float(height-1)*2-0.25)*a;pixels[i+2]=Float((x+y)%17)/16*a;pixels[i+3]=a
  }}
  let input=CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:nil)
  let output=try mesh?.applying(to:input) ?? input
  let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
  let context=CIContext(options:[.workingColorSpace:space,.outputColorSpace:space,.workingFormat:CIFormat.RGBAf.rawValue])
  context.render(output,toBitmap:&pixels,rowBytes:width*16,bounds:input.extent,format:.RGBAf,colorSpace:nil)
  var top=[Float](repeating:0,count:pixels.count)
  for y in 0..<height {top.replaceSubrange(y*width*4..<(y+1)*width*4,with:pixels[y*width*4..<(y+1)*width*4])}
  try top.withUnsafeBytes{Data($0)}.write(to:URL(fileURLWithPath:CommandLine.arguments[4]))
 }
}
'''

CPP_SOURCE = r'''
#include "liquify.hpp"
#include <fstream>
#include <iostream>
int main(int argc,char **argv) {try {
 nlohmann::json value;std::ifstream(argv[1])>>value;filmdevelop::LiquifyMesh mesh(value);size_t w=std::stoul(argv[2]),h=std::stoul(argv[3]);photocore::Image input(w,h);
 for(size_t y=0;y<h;y++)for(size_t x=0;x<w;x++){float a=x%13==0 ? 0 : (y%7==0 ? .35f : 1);input.pixels[y*w+x]={float(x)/float(w-1)*4*a,(float(y)/float(h-1)*2-.25f)*a,float((x+y)%17)/16*a,a};}
 auto output=filmdevelop::apply_liquify(std::move(input),mesh);std::ofstream file(argv[4],std::ios::binary);file.write((char*)output.pixels.data(),output.pixels.size()*sizeof(photocore::Pixel));
}catch(const std::exception &e){std::cerr<<e.what()<<std::endl;return 1;}}
'''

(OUT/'probe.swift').write_text(SWIFT_SOURCE)
(OUT/'probe.cpp').write_text(CPP_SOURCE)
run(['node','--input-type=module','-e', """
import fs from 'node:fs';
await import('./PhotoStyleApp/Web/liquify-core.js');
const m=new globalThis.PhotoLiquifyCore.LiquifyMesh(131,103);
m.beginStroke({x:45,y:45},{radius:30,strength:.8});m.moveStroke({x:58,y:49});m.moveStroke({x:66,y:60});m.endStroke();
fs.writeFileSync(process.argv[1],JSON.stringify(m.toData()));
""",OUT/'mesh.json'])
(OUT/'identity.json').write_text('null')
run(['xcrun','swiftc','-O','-parse-as-library','-swift-version','5',ROOT/'PhotoStyleApp/PhotoLiquifyProcessor.swift',OUT/'probe.swift','-o',OUT/'probe-swift'])
run(['c++','-std=c++17','-O2','-Iengine/cpp','-Iexperiments/PhotoCoreCpp/include','-Iexperiments/PhotoCoreCpp/src','-Iexperiments/PhotoCoreCpp/third_party',OUT/'probe.cpp',ROOT/'experiments/PhotoCoreCpp/src/core.cpp','-o',OUT/'probe-cpp'])
results=[]
for mesh in ['identity','mesh']:
    for width,height in [(131,103),(261,205),(67,53)]:
        values={}
        for kind in ['cpp','swift']:
            output=OUT/f'{mesh}-{width}-{kind}.f32'
            run([OUT/f'probe-{kind}',OUT/f'{mesh}.json',width,height,output])
            values[kind]=struct.unpack('<'+'f'*(width*height*4),output.read_bytes())
        left,right=values['cpp'],values['swift']
        assert all(math.isfinite(v) for v in left+right)
        errors=[abs(a-b) for a,b in zip(left,right)]
        tolerance=0 if mesh=='identity' else 0.0002
        assert max(errors)<=tolerance,(mesh,width,max(errors))
        assert max(left)>3.9 and max(right)>3.9 and min(left)<0 and min(right)<0
        assert all(-1e-6<=v<=1+1e-6 for v in right[3::4])
        # 邊界固定；全零 alpha 的像素維持預乘零 RGB。
        for y in range(height):
            for x in range(width):
                index=(y*width+x)*4
                if right[index+3]==0:
                    assert all(abs(v)<1e-6 for v in right[index:index+3])
        results.append({'case':'空網格原樣' if mesh=='identity' else '正式 Web 筆畫網格', 'width':width,'height':height,
                        'maxError':max(errors),'meanError':sum(errors)/len(errors),'tolerance':tolerance,
                        'peakHDR':max(right),'minimumExtendedColor':min(right),'passed':True})
mesh=json.loads((OUT/'mesh.json').read_text())
invalid={}
invalid['版本']=dict(mesh,version=2)
invalid['參考尺寸']=dict(mesh,referenceWidth=1)
invalid['陣列長度']=dict(mesh,dx=mesh['dx'][:-1])
for name in ['固定邊界','超出來源','網格翻折']:
    value=copy.deepcopy(mesh)
    if name=='固定邊界': value['dx'][0]=0.01
    elif name=='超出來源': value['dx'][value['columns']+1]=2
    else:
        index=10*value['columns']+10
        value['dx'][index]=value['spacing']/(value['referenceWidth']-1)*2
        value['dx'][index+1]=-value['spacing']/(value['referenceWidth']-1)*2
    invalid[name]=value
for name,value in invalid.items():
    path=OUT/f'invalid-{name}.json';path.write_text(json.dumps(value))
    for kind in ['cpp','swift']:
        target=OUT/f'invalid-{name}-{kind}.f32'
        if target.exists(): target.unlink()
        p=subprocess.run([str(OUT/f'probe-{kind}'),str(path),'131','103',str(target)],capture_output=True,text=True)
        assert p.returncode==1 and not target.exists(),(name,kind,p.returncode,p.stderr)
    results.append({'case':'兩平台拒絕'+name,'passed':True})
windows={'executed':False,'scope':'C++ 像素驗證在 macOS 執行，不等同 Windows 實機驗收。',
         'command':['cmake','--build','build/windows-cross/native','-j4']}
if args.windows_build:
    p=run(windows['command']);(OUT/'windows-build.log').write_text(p.stdout+p.stderr)
    windows.update({'executed':True,'passed':True,'scope':'Windows x64 正式原生引擎交叉編譯通過；未執行 Windows 實機程式。'})
sources=['PhotoStyleApp/PhotoLiquifyProcessor.swift','engine/cpp/liquify.hpp','engine/cpp/render_pipeline.hpp','engine/macos/main.swift','engine/windows/main.cpp','PhotoStyleApp/Web/liquify-core.js']
report={'suite':'正式液化原生 Smoke','passed':True,'cases':results,'windows':windows,
        'method':'直接使用正式 Web core 產生非正方形且含末端短格的 mesh；同一 extended-linear Float32 預乘 RGBA fixture 在 C++ 與 Core Image Metal 取樣。輸入含 HDR、負通道、半透明及透明像素，驗證原尺寸、放大與縮小三解析度。空網格要求 Float32 數值零差，不要求正負零符號位元相同。',
        'sourceSHA256':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in sources},'commands':commands}
(OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'passed':True,'cases':len(results),'report':str(OUT/'report.json'),'windowsCrossCompile':windows['executed']},ensure_ascii=False))
