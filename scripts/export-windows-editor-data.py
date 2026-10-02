#!/usr/bin/env python3
"""從 Swift 參考實作匯出白平衡矩陣；執行時由 C++／GPU 套用，不依賴 Apple API。"""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'experiments/PhotoCoreCpp/data/editor'
SOURCES = ['PhotoStyleShared/Sources/PhotoStyleShared/PhotoToneProcessor.swift', 'PhotoStyleApp/PhotoStyleProcessor.swift', 'PhotoStyleShared/Sources/PhotoStyleShared/PhotoVignetteProcessor.swift']
fingerprint = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in SOURCES}
parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
if args.check:
    subprocess.run(['python3',str(ROOT/'scripts/export-windows-frame-data.py'),'--check'],check=True)
    manifest = json.loads((OUT / 'manifest.json').read_text())
    assert manifest['sources'] == fingerprint, 'Swift 白平衡已更新，需重新匯出'
    assert hashlib.sha256((OUT / 'white-balance.f32').read_bytes()).hexdigest() == manifest['sha256']
    for name, digest in manifest['files'].items():
        assert hashlib.sha256((OUT / name).read_bytes()).hexdigest() == digest
    print('共用編輯資料與 Swift 來源一致')
    raise SystemExit
BUILD = ROOT / 'build/windows-editor-data'
BUILD.mkdir(parents=True, exist_ok=True)
OUT.mkdir(parents=True, exist_ok=True)
source = BUILD / 'Export.swift'
source.write_text('''import CoreImage
import Foundation
@main enum Export {
 static func main() throws {
  let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
  let context=CIContext(options:[.workingColorSpace:space,.outputColorSpace:space,.workingFormat:CIFormat.RGBAf])
  let pixels:[Float]=[1,0,0,1,0,1,0,1,0,0,1,1,0,0,0,1,0.23,0.41,0.08,1,1.5,0.07,0.8,1]
  let input=CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:96,size:CGSize(width:6,height:1),format:.RGBAf,colorSpace:space)
  var matrices=[Float](), worst:Float=0
  for tint in stride(from:-140,through:140,by:2) {
   for warmth in stride(from:-140,through:140,by:2) {
    // 對應 Swift app 的座標，並涵蓋 plan 的較大溫度／色偏範圍。
    let image=input.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:6500,y:0),"inputTargetNeutral":CIVector(x:6500-Double(warmth)*18,y:-Double(tint)*0.6)])
    var output=[Float](repeating:0,count:24)
    context.render(image,toBitmap:&output,rowBytes:96,bounds:input.extent,format:.RGBAf,colorSpace:space)
    for c in 0..<3 {
     matrices += [output[c],output[4+c],output[8+c]]
     for x in 3..<6 {
      let expected=output[c]*pixels[x*4]+output[4+c]*pixels[x*4+1]+output[8+c]*pixels[x*4+2]
      worst=max(worst,abs(output[x*4+c]-expected))
     }
    }
   }
  }
  guard worst<0.00001,matrices.allSatisfy({$0.isFinite}) else {throw NSError(domain:"白平衡線性／HDR 檢查失敗",code:1)}
  try matrices.withUnsafeBytes{try Data($0).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
  print("Swift 白平衡矩陣已匯出；線性檢查最大誤差",worst)
 }
}
''')
subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', str(source), '-o', str(BUILD / 'export')], check=True)
subprocess.run([str(BUILD / 'export'), str(OUT / 'white-balance.f32')], check=True)
manifest = {'schema': 1, 'minimum': -140, 'step': 2, 'dimension': 141, 'sources': fingerprint,
            'sha256': hashlib.sha256((OUT / 'white-balance.f32').read_bytes()).hexdigest()}
processor = (ROOT / SOURCES[1]).read_text()
start = processor.index('    private static func toneColorMapping(')
end = processor.index('    private static func applyToneRegionColorCast(', start)
mapping = processor[start:end].replace('private static func', 'static func').replace('style: PhotoStyle', 'style: String')
mapping = re.sub(r'case \.(\w+):', lambda m: m[0] if m[1] in ['shadows', 'midtones', 'highlights'] else 'case "' + m[1] + '":', mapping)
mapping = mapping.replace('style.filmStock?.family ?? "negative"', 'families[style] ?? "negative"').replace('style.isMonochrome', 'monochromes.contains(style)')
catalog = json.loads((ROOT / 'desktop/internal/recipes/catalog.json').read_text())['styles']
profiles = json.loads((ROOT / 'experiments/PhotoCoreCpp/data/film-profiles.json').read_text())['profiles']
families = '[' + ','.join(json.dumps(k) + ':' + json.dumps(v['family']) for k, v in profiles.items()) + ']'
monochromes = '[' + ','.join(json.dumps(s['id']) for s in catalog if s['isMonochrome']) + ']'
ids = '[' + ','.join(json.dumps(s['id']) for s in catalog) + ']'
tone_source = BUILD / 'Tone.swift'
tone_source.write_text('''import Foundation
import CoreImage
enum Reference {
 enum ToneRegion {case shadows,midtones,highlights}
 struct ToneColorMapping {
  var saturation:Double,contrast:Double,brightness:Double,redBias:Double,greenBias:Double,blueBias:Double,blackLift:Double,whitePull:Double
 }
 static let families:[String:String]=''' + families + '\n static let monochromes:Set<String>=' + monochromes + '\n' + mapping + '''
}
@main enum Export {
 static func main() throws {
  let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
  let context=CIContext(options:[.workingColorSpace:space,.outputColorSpace:space,.workingFormat:CIFormat.RGBAf])
  let pixels:[Float]=[1,0,0,1,0,1,0,1,0,0,1,1,0,0,0,1,0.23,0.41,0.08,1,1.5,0.07,0.8,1]
  let input=CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:96,size:CGSize(width:6,height:1),format:.RGBAf,colorSpace:space)
  let n=16385
  let width=257,height=65
  var ramp=[Float](repeating:1,count:width*height*4)
  for i in 0..<(width*height) {for c in 0..<3 {ramp[i*4+c] = -1+5*Float(min(i,n-1))/Float(n-1)}}
  let gradient=CIImage(bitmapData:ramp.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:space)
  let folder=URL(fileURLWithPath:CommandLine.arguments[1]);var styles:[String:Any]=[:]
  for id in ''' + ids + ''' {
   var zones:[[String:Any]]=[]
   for (index,region) in [Reference.ToneRegion.shadows,.midtones,.highlights].enumerated() {
    let m=Reference.toneColorMapping(for:id,region:region)
    let filtered=input.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:m.saturation,kCIInputBrightnessKey:m.brightness,kCIInputContrastKey:m.contrast])
    var output=[Float](repeating:0,count:24)
    context.render(filtered,toBitmap:&output,rowBytes:96,bounds:input.extent,format:.RGBAf,colorSpace:space)
    var rows:[[Double]]=[];let bias=[m.redBias,m.greenBias,m.blueBias]
    for c in 0..<3 {
     let row=[Double(output[c]-output[12+c]),Double(output[4+c]-output[12+c]),Double(output[8+c]-output[12+c])]
     for x in 4..<6 {
      let v=row[0]*Double(pixels[x*4])+row[1]*Double(pixels[x*4+1])+row[2]*Double(pixels[x*4+2])+Double(output[12+c])
      guard abs(v-Double(output[x*4+c]))<0.00001 else {throw NSError(domain:"三區色調矩陣檢查失敗",code:1)}
     }
     rows.append(row+[Double(output[12+c])+bias[c]])
    }
    var zone:[String:Any]=["rows":rows]
    if m.blackLift>0.001 || m.whitePull>0.001 {
     let image=gradient.applyingFilter("CIToneCurve",parameters:["inputPoint0":CIVector(x:0,y:m.blackLift),"inputPoint1":CIVector(x:0.25,y:0.25+m.blackLift*0.45),"inputPoint2":CIVector(x:0.5,y:0.5),"inputPoint3":CIVector(x:0.78,y:0.78-m.whitePull*0.35),"inputPoint4":CIVector(x:1,y:1-m.whitePull)])
     var sampled=[Float](repeating:0,count:width*height*4)
     context.render(image,toBitmap:&sampled,rowBytes:width*16,bounds:gradient.extent,format:.RGBAf,colorSpace:space)
     let curve=(0..<n).map{sampled[$0*4]}
     guard curve.allSatisfy({$0.isFinite}),curve[6554]>0.5 else {throw NSError(domain:"三區色調曲線非有限值",code:1)}
     let file=id+"-"+String(index)+".f32"
     try curve.withUnsafeBytes{try Data($0).write(to:folder.appendingPathComponent(file))};zone["curve"]=file
    }
    zones.append(zone)
   }
   styles[id]=zones
  }
  try JSONSerialization.data(withJSONObject:styles,options:[.sortedKeys]).write(to:folder.appendingPathComponent("tone-zones.json"))
  // 暗角是與色彩無關的徑向乘數；採樣單位強度，再由執行期套用強度指數。
  let white=CIImage(color:CIColor(red:1,green:1,blue:1,colorSpace:space)!).cropped(to:CGRect(x:0,y:0,width:8194,height:512))
  let vignette=white.applyingFilter("CIVignette",parameters:[kCIInputRadiusKey:1.8,kCIInputIntensityKey:1])
  var radial=[Float](repeating:0,count:4097*4)
  context.render(vignette,toBitmap:&radial,rowBytes:4097*16,bounds:CGRect(x:4096.5,y:255.5,width:4097,height:1),format:.RGBAf,colorSpace:space)
  let gains=(0..<4097).map{radial[$0*4]}
  guard gains[0]>0.99999,gains[256]>0.5,gains.allSatisfy({$0.isFinite && $0>=0 && $0<=1}) else {throw NSError(domain:"暗角曲線檢查失敗",code:1)}
  try gains.withUnsafeBytes{try Data($0).write(to:folder.appendingPathComponent("vignette.f32"))}
 }
}
''')
subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', str(tone_source), '-o', str(BUILD / 'tones')], check=True)
subprocess.run([str(BUILD / 'tones'), str(OUT)], check=True)
subprocess.run(['python3',str(ROOT/'scripts/export-windows-frame-data.py')],check=True)
manifest['files'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in OUT.iterdir() if p.name != 'manifest.json'}
(OUT / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
