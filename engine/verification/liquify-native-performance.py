#!/usr/bin/env python3
"""液化 FUNCTION 級前後差分與暖機效能；baseline 指向另一份原生來源快照。"""
import argparse
import filecmp
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import time

ROOT=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline',type=Path,default=ROOT/'build/liquify-optimization/baseline')
parser.add_argument('--output',type=Path,default=ROOT/'build/liquify-optimization/native-performance')
parser.add_argument('--report',type=Path,default=ROOT/'build/liquify-optimization/native-report.json')
parser.add_argument('--keep-pixels',action='store_true',help='保留所有合成 Float32 像素，否則比較後只保留 SHA-256。')
args=parser.parse_args()
BASE=args.baseline.resolve();OUT=args.output.resolve();OUT.mkdir(parents=True,exist_ok=True)
for path in ['PhotoStyleApp/PhotoLiquifyProcessor.swift','engine/cpp/liquify.hpp']:
    if not (BASE/path).is_file(): raise SystemExit('baseline 須含原生來源快照：'+path)
commands=[]
def run(command):
    started=time.perf_counter();p=subprocess.run([str(v) for v in command],cwd=ROOT,capture_output=True,text=True)
    commands.append({'command':[str(v) for v in command],'seconds':round(time.perf_counter()-started,4),'returncode':p.returncode})
    if p.returncode: raise RuntimeError(p.stderr or p.stdout)
    return p

CPP_SOURCE = r'''
#include "liquify.hpp"
#include <fstream>
#include <iostream>
#include <chrono>
#include <sys/resource.h>
using Clock=std::chrono::steady_clock;
double elapsed(Clock::time_point t){return std::chrono::duration<double,std::milli>(Clock::now()-t).count();}
double median(std::vector<double> v){std::sort(v.begin(),v.end());return v[v.size()/2];}
int main(int argc,char **argv){try{
 nlohmann::json j;std::ifstream(argv[1])>>j;size_t w=std::stoul(argv[2]),h=std::stoul(argv[3]);std::vector<double> construction,apply;
 for(int i=0;i<7;i++){auto t=Clock::now();filmdevelop::LiquifyMesh q(j);construction.push_back(elapsed(t));}
 filmdevelop::LiquifyMesh mesh(j);photocore::Image source(w,h);
 for(size_t y=0;y<h;y++)for(size_t x=0;x<w;x++){float a=x%13==0?0:(y%7==0?.35f:1);source.pixels[y*w+x]={float(x)/float(w-1)*4*a,(float(y)/float(h-1)*2-.25f)*a,float((x+y)%17)/16*a,a};}
 for(int i=0;i<3;i++){auto warm=filmdevelop::apply_liquify(source,mesh);if(warm.width!=w)return 2;}
 photocore::Image output(1,1);
 for(int i=0;i<9;i++){auto input=source;auto t=Clock::now();output=filmdevelop::apply_liquify(std::move(input),mesh);apply.push_back(elapsed(t));}
 std::ofstream(argv[4],std::ios::binary).write((const char*)output.pixels.data(),output.pixels.size()*16);
 rusage usage{};getrusage(RUSAGE_SELF,&usage);
 nlohmann::json report{{"constructorMedianMs",median(construction)},{"applyMedianMs",median(apply)},{"peakRSSBytes",usage.ru_maxrss},{"width",w},{"height",h}};
#ifdef LIQUIFY_OPTIMIZED
 size_t affected=0,spansBytes=0;for(auto &row:mesh.activeRows)spansBytes+=row.capacity()*sizeof(std::pair<size_t,size_t>);
 if(!mesh.identity)for(size_t y=0;y<h;y++)for(size_t x=0;x<w;x++){
  size_t ix=std::min(mesh.columns-2,size_t((double(x)/(w-1)*(mesh.referenceWidth-1))/mesh.spacing));
  size_t iy=std::min(mesh.rows-2,size_t((double(y)/(h-1)*(mesh.referenceHeight-1))/mesh.spacing));
  for(const auto &span:mesh.activeRows[iy])if(ix>=span.first&&ix<span.second){affected++;break;}
 }
 bool sparse=affected<w*h/2;report["affectedPixels"]=affected;report["scratchPixelBytes"]=mesh.identity?0:(sparse?affected:w*h)*16;
 report["axisAndOffsetBytes"]=mesh.identity?0:(w+h)*16+(mesh.columns+h+1)*sizeof(size_t);
 report["retainedMeshBytes"]=(mesh.dx.capacity()+mesh.dy.capacity())*sizeof(float)+mesh.activeRows.capacity()*sizeof(mesh.activeRows[0])+spansBytes;
#else
 report["scratchPixelBytes"]=mesh.identity?0:w*h*16;report["axisAndOffsetBytes"]=0;
 report["retainedMeshBytes"]=(mesh.dx.capacity()+mesh.dy.capacity())*sizeof(float);
#endif
 std::cout<<report.dump()<<std::endl;
}catch(std::exception &e){std::cerr<<e.what()<<std::endl;return 1;}}
'''

SWIFT_SOURCE = r'''
import Foundation
import CoreImage
import Darwin
@main struct Perf {
 static func main() throws {
  let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]));let w=Int(CommandLine.arguments[2])!,h=Int(CommandLine.arguments[3])!
  func median(_ v:[Double])->Double { v.sorted()[v.count/2] }
  func elapsed(_ t:Double)->Double {(ProcessInfo.processInfo.systemUptime-t)*1000}
  var construction=[Double](),applying=[Double](),rendering=[Double]()
  for _ in 0..<7 {try autoreleasepool {let t=ProcessInfo.processInfo.systemUptime;let m=try JSONDecoder().decode(PhotoLiquifyMesh.self,from:data);construction.append(elapsed(t));assert(m.dx.count>0)}}
  let mesh=try JSONDecoder().decode(PhotoLiquifyMesh.self,from:data)
  var pixels=[Float](repeating:0,count:w*h*4)
  for y in 0..<h {for x in 0..<w {let i=(y*w+x)*4,a:Float=x%13==0 ? 0 : (y%7==0 ? 0.35:1);pixels[i]=Float(x)/Float(w-1)*4*a;pixels[i+1]=(Float(y)/Float(h-1)*2-0.25)*a;pixels[i+2]=Float((x+y)%17)/16*a;pixels[i+3]=a}}
  let image=CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:nil)
  let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
  let context=CIContext(options:[.workingColorSpace:space,.outputColorSpace:space,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])
  for _ in 0..<3 {try autoreleasepool {let result=try mesh.applying(to:image);context.render(result,toBitmap:&pixels,rowBytes:w*16,bounds:image.extent,format:.RGBAf,colorSpace:nil)}}
  for _ in 0..<31 {try autoreleasepool {let t=ProcessInfo.processInfo.systemUptime;let result=try mesh.applying(to:image);applying.append(elapsed(t));assert(result.extent==image.extent)}}
  for _ in 0..<9 {try autoreleasepool {let t=ProcessInfo.processInfo.systemUptime;let result=try mesh.applying(to:image);context.render(result,toBitmap:&pixels,rowBytes:w*16,bounds:image.extent,format:.RGBAf,colorSpace:nil);rendering.append(elapsed(t))}}
  try pixels.withUnsafeBytes{Data($0)}.write(to:URL(fileURLWithPath:CommandLine.arguments[4]))
  var usage=rusage();getrusage(RUSAGE_SELF,&usage)
  var result:[String:Any]=["decodeConstructorMedianMs":median(construction),"applyingGraphMedianMs":median(applying),"applyAndRenderMedianMs":median(rendering),"peakRSSBytes":usage.ru_maxrss,"width":w,"height":h]
  result["meshArrayPayloadBytes"]=mesh.dx.count*8
  #if LIQUIFY_OPTIMIZED
  result["sharedMapPayloadBytes"]=mesh.isIdentity ? 0 : mesh.dx.count*16
  result["perApplyingStagingPayloadBytes"]=0
  #else
  result["sharedMapPayloadBytes"]=0
  result["perApplyingStagingPayloadBytes"]=mesh.isIdentity ? 0 : mesh.dx.count*32
  #endif
  print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)
 }
}
'''

FIXTURES = r'''
import fs from 'node:fs';
await import(process.argv[1]);
const {LiquifyMesh}=globalThis.PhotoLiquifyCore;
for (const name of ['identity','local','dispersed','full','edge']) {
 const m=new LiquifyMesh(1024,768);const points=name==='edge'?[[4,4],[1018,762]]:name==='local'?[[350,300]]:name==='dispersed'?[[180,170],[840,170],[180,600],[840,600]]:[];
 for(const [x,y] of points){m.beginStroke({x,y},{radius:60,strength:.8});m.moveStroke({x:x+20,y:y+8});m.endStroke();}
 const data=m.toData()||{version:1,referenceWidth:m.width,referenceHeight:m.height,spacing:m.spacing,columns:m.columns,rows:m.rows,dx:Array(m.dx.length).fill(0),dy:Array(m.dy.length).fill(0)};
 if(name==='full')for(let y=1;y<m.rows-1;y++)for(let x=1;x<m.columns-1;x++){let i=y*m.columns+x,u=x*m.spacing/(m.width-1),v=y*m.spacing/(m.height-1);let a=Math.sin(u*Math.PI)*Math.sin(v*Math.PI);data.dx[i]=.01*a*a;data.dy[i]=-.007*a*a;}
 fs.writeFileSync(process.argv[2]+'/'+name+'.json',JSON.stringify(data));
}
'''

(OUT/'perf.cpp').write_text(CPP_SOURCE)
(OUT/'perf.swift').write_text(SWIFT_SOURCE)
run(['node','--input-type=module','-e',FIXTURES,(ROOT/'PhotoStyleApp/Web/liquify-core.js').as_uri(),OUT])
for state,source in [('before',BASE),('after',ROOT)]:
    cppFlags=['-DLIQUIFY_OPTIMIZED'] if state=='after' else []
    run(['c++','-O2','-std=c++17']+cppFlags+['-I'+str(source/'engine/cpp'),'-Iexperiments/PhotoCoreCpp/include','-Iexperiments/PhotoCoreCpp/src','-Iexperiments/PhotoCoreCpp/third_party',OUT/'perf.cpp',ROOT/'experiments/PhotoCoreCpp/src/core.cpp','-o',OUT/(state+'-cpp')])
    swiftFlags=['-D','LIQUIFY_OPTIMIZED'] if state=='after' else []
    run(['xcrun','swiftc','-O']+swiftFlags+['-parse-as-library','-swift-version','5',source/'PhotoStyleApp/PhotoLiquifyProcessor.swift',OUT/'perf.swift','-o',OUT/(state+'-swift')])
comparisons=[]
for kind in ['cpp','swift']:
    for case in ['identity','local','dispersed','full','edge']:
        for width,height in [(1024,768),(2048,1536),(131,103)]:
            pair={}
            for state in ['before','after']:
                target=OUT/f'{state}-{kind}-{case}-{width}.f32'
                p=run([OUT/f'{state}-{kind}',OUT/f'{case}.json',width,height,target])
                row=json.loads(p.stdout);row['outputSHA256']=hashlib.sha256(target.read_bytes()).hexdigest();pair[state]=row
            left=OUT/f'before-{kind}-{case}-{width}.f32';right=OUT/f'after-{kind}-{case}-{width}.f32'
            equal=filecmp.cmp(left,right,shallow=False)
            assert equal,(kind,case,width,'Float32 位元組不一致')
            comparisons.append({'platform':kind,'case':case,'width':width,'height':height,'bitwiseEqual':equal,**pair})
            if not args.keep_pixels: left.unlink();right.unlink()
sources=['PhotoStyleApp/PhotoLiquifyProcessor.swift','engine/cpp/liquify.hpp','engine/cpp/render_pipeline.hpp','engine/windows/main.cpp']
report={'suite':'液化原生 FUNCTION 級最佳化','passed':True,'bitwiseCases':len(comparisons),
        'environment':{'system':platform.platform(),'machine':platform.machine()},
        'method':{'comparison':'每個平台內比較舊／新實作完整 Float32 RGBA 位元組；fixture 含負通道、HDR、半透明及透明，網格涵蓋空白、局部、分散、全圖與邊界。',
                  'warmup':'每個程序同一 CIContext／影像先完成 3 次 apply + render，排除 shader 編譯與首次 GPU 配置；cacheIntermediates=false。C++ 亦先執行 3 次完整函式。',
                  'samples':'constructor 7 次、Swift applying 建圖 31 次、實際 apply/render 9 次，均取中位數；同案例舊／新程序相鄰執行。',
                  'constructor':'Swift 包含 JSONDecoder 解碼；C++ 從已解析的 JSON 建構。僅作同平台前後比較。',
                  'cpuTiming':'計時前先建立 owned input，計時包含 apply_liquify 內部 scratch、取樣與回寫；來源拷貝不計入。',
                  'memory':'scratchPixelBytes、axisAndOffsetBytes、retainedMeshBytes 為演算法實際資料元素及capacity的bytes，未含allocator/GPU框架。Swift mapPayload僅指RGBAf資料；不等於CIImage全部記憶體。peakRSSBytes是整個子程序的高水位，不能當作單一函式節省量。',
                  'limitations':'數字依硬體、頻率與同時負載改變；identity函式極短，可能低於計時器解析度。'},
        'comparisons':comparisons,
        'sourceSHA256':{state:{name:hashlib.sha256((source/name).read_bytes()).hexdigest() for name in sources if (source/name).is_file()} for state,source in [('before',BASE),('after',ROOT)]},
        'commands':commands}
args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'passed':True,'bitwiseCases':len(comparisons),'report':str(args.report)},ensure_ascii=False))
