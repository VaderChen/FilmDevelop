#!/usr/bin/env python3
"""從現有 Swift 風格匯出跨平台色彩表；空間效果另外保留，不能烘焙進色彩表。"""
import argparse,hashlib,json,re,subprocess
from pathlib import Path
from swift_package_product import build_product
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
sources=['PhotoStyleApp/PhotoStyleProcessor.swift','PhotoStyleShared/Sources/PhotoStyleShared/PhotoCameraProcessor.swift']
output=root/'experiments/PhotoCoreCpp/data/digital-looks';manifest=output/'manifest.json'
fingerprint={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sources}
if args.check:
 data=json.loads(manifest.read_text());assert data['sources']==fingerprint,'Swift 風格已更新，需重新匯出跨平台色彩資料'
 for style in data['styles']:
  if 'file' in style:assert hashlib.sha256((output/style['file']).read_bytes()).hexdigest()==style['sha256']
  if 'outputCurve' in style:assert hashlib.sha256((output/style['outputCurve']).read_bytes()).hexdigest()==style['outputCurveSHA256']
  if 'monochromeCurve' in style:assert hashlib.sha256((output/style['monochromeCurve']).read_bytes()).hexdigest()==style['monochromeSHA256']
 print('數位／相機風格資料與 Swift 來源一致');raise SystemExit
build=root/'build/windows-style-data';build.mkdir(parents=True,exist_ok=True);output.mkdir(parents=True,exist_ok=True)
s=(root/sources[0]).read_text()
def function(name):
 start=s.index('    private static func '+name+'(');brace=s.index('{',start);n=1;i=brace+1
 while n:
  n+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[start:i].replace('private static func','static func')
functions='\n'.join(function(n) for n in ['applyJapaneseColor1Signature','applyJapaneseColor2Signature','applyFujiClassicChromeSignature','applyFujiClassicNegSignature'])
look=s[s.index('        switch style {',s.index('private static func applyLook')):s.index('        default:',s.index('private static func applyLook'))]
look=re.sub(r'case \.(\w+):',r'case "\1":',look).replace('        switch style {','switch style {')
look+='default: throw NSError(domain: "未知數位風格", code: 1)\n}\nreturn filtered'
code='''import Foundation
import CoreImage
import PhotoStyleShared
var casts: [[String: Any]] = []
var spatial: [[String: Any]] = []
var splitToneCurve=false
var toneCurve: [String:Any] = [:]
extension CIImage {
 func recordCurve(_ name:String, parameters:[String:Any]) -> CIImage {
  if !splitToneCurve {return self.applyingFilter(name,parameters:parameters)}
  toneCurve=parameters;return self
 }
 func recordSpatial(_ name: String, parameters: [String: Any]) -> CIImage {
  spatial.append(["filter":name,"parameters":parameters]);return self
 }
}
enum Reference {
 enum ToneRegion {case shadows,midtones,highlights}
 static func applyColorControls(to image:CIImage,saturation:Double,brightness:Double,contrast:Double)->CIImage {
  image.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:saturation,kCIInputBrightnessKey:brightness,kCIInputContrastKey:contrast])
 }
 static func applyToneRegionColorCast(to image:CIImage,sourceForMask:CIImage,region:ToneRegion,redBias:Double,greenBias:Double,blueBias:Double,opacity:Double)->CIImage {
  casts.append(["region":region == .shadows ? 0 : (region == .midtones ? 1 : 2),"bias":[redBias*opacity,greenBias*opacity,blueBias*opacity]]);return image
 }
 static func look(_ style:String,_ correctedBaseImage:CIImage) throws ->CIImage {
 let styleBaseImage = style == "japaneseBWStrong" ? correctedBaseImage.applyingFilter("CIPhotoEffectNoir") : correctedBaseImage.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:0])
 let filtered:CIImage
'''+look+'\n}\n'+functions+'\n}\n'
code=code.replace('.applyingFilter("CIToneCurve"','.recordCurve("CIToneCurve"').replace('.applyingFilter("CIBloom"','.recordSpatial("CIBloom"').replace('.applyingFilter("CISharpenLuminance"','.recordSpatial("CISharpenLuminance"')
code+='''
@main enum Export {
 static func main() throws {
  let n=65, width=n*n,height=n
  let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
  let context=CIContext(options:[.workingColorSpace:space,.outputColorSpace:space,.workingFormat:CIFormat.RGBAf])
  var pixels=[Float](repeating:1,count:width*height*4)
  func linear(_ v:Double)->Float {Float(v<=0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4))}
  for b in 0..<n {for g in 0..<n {for r in 0..<n {
   let i=(b*n*n+g*n+r)*4
   pixels[i]=linear(Double(r)/Double(n-1));pixels[i+1]=linear(Double(g)/Double(n-1));pixels[i+2]=linear(Double(b)/Double(n-1))
  }}}
  let data=pixels.withUnsafeBytes{Data($0)}
  let input=CIImage(bitmapData:data,bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:space)
  let ids=["autoDetection","japaneseColor1","japaneseColor2","japaneseBWStrong","japaneseBWStandard","japaneseBWSoft","fujiProvia","fujiClassicChrome","fujiClassicNeg"]+PhotoCameraProfile.all.map(\\.id)
  let folder=URL(fileURLWithPath:CommandLine.arguments[1]);var styles:[[String:Any]]=[]
  for id in ids {
   casts=[];spatial=[];splitToneCurve=false;toneCurve=[:]
   var result:CIImage
   if let camera=PhotoCameraProfile.profile(id:id) {result=PhotoCameraProcessor.apply(to:input,profile:camera)}
   else {result=try Reference.look(id,input)}
   // 色調曲線在色彩混合之後執行；不可把夾限邊界一起烘焙進低解析三維表。
   if !casts.isEmpty {
    casts=[];spatial=[];splitToneCurve=true
    result=try Reference.look(id,input)
   }
   var values=[Float](repeating:0,count:pixels.count)
   context.render(result,toBitmap:&values,rowBytes:width*16,bounds:input.extent,format:.RGBAf,colorSpace:space)
   guard values.allSatisfy({$0.isFinite}) else {throw NSError(domain:"色彩表非有限值",code:1)}
   let name=id+".rgba32f"
   try values.withUnsafeBytes{try Data($0).write(to:folder.appendingPathComponent(name))}
   for i in spatial.indices where spatial[i]["filter"] as? String == "CISharpenLuminance" {
    let params=spatial[i]["parameters"] as! [String:Double], amount=params[kCIInputSharpnessKey]!
    let width=65, centre=32
    var pulse=[Float](repeating:0,count:width*4)
    for x in 0..<width { pulse[x*4+3]=1 }
    pulse[centre*4]=1;pulse[centre*4+1]=1;pulse[centre*4+2]=1
    let field=CIImage(bitmapData:pulse.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:CGSize(width:width,height:1),format:.RGBAf,colorSpace:space)
    let filtered=field.clampedToExtent().applyingFilter("CISharpenLuminance",parameters:params)
    var measured=[Float](repeating:0,count:pulse.count)
    context.render(filtered,toBitmap:&measured,rowBytes:width*16,bounds:field.extent,format:.RGBAf,colorSpace:space)
    var kernel=(0...12).map { j in j == 0 ? 1-(Double(measured[centre*4])-1)/amount : -Double(measured[(centre+j)*4])/amount }
    let total=kernel[0]+2*kernel.dropFirst().reduce(0,+)
    kernel=kernel.map{$0/sqrt(total)}
    spatial[i]["kernel"]=kernel
   }
   var metadata:[String:Any] = ["id":id,"file":name,"dimension":n,"casts":casts,"spatial":spatial]
   func sample(_ pixels:[Float],_ width:Int,_ height:Int) throws -> [Float] {
    let savedCasts=casts,savedSpatial=spatial
    defer {casts=savedCasts;spatial=savedSpatial}
    let image=CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:space)
    let result:CIImage
    if let camera=PhotoCameraProfile.profile(id:id) {result=PhotoCameraProcessor.apply(to:image,profile:camera)}
    else {result=try Reference.look(id,image)}
    var sampled=[Float](repeating:0,count:pixels.count)
    context.render(result,toBitmap:&sampled,rowBytes:width*16,bounds:image.extent,format:.RGBAf,colorSpace:space)
    return sampled
   }
   if casts.isEmpty && spatial.isEmpty {
    // 只有真實彩色／HDR 樣本驗證為灰階函數的風格才使用一維曲線。
    // 其餘保留三維色彩表，不能把所有黑白風格假設成相同的亮度權重。
    let width=512
    var rgb=[Float](repeating:1,count:width*4),gray=rgb
    for i in 0..<width {
     for c in 0..<3 {rgb[i*4+c] = Float((i*(13+c*24))%509)/508*4-0.1}
     let y=rgb[i*4]*0.2125+rgb[i*4+1]*0.7154+rgb[i*4+2]*0.0721
     for c in 0..<3 {gray[i*4+c]=y}
    }
    func run(_ pixels:[Float],_ width:Int,_ height:Int) throws -> [Float] {
     let image=CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:space)
     let result:CIImage
     if let camera=PhotoCameraProfile.profile(id:id) {result=PhotoCameraProcessor.apply(to:image,profile:camera)}
     else {result=try Reference.look(id,image)}
     var sampled=[Float](repeating:0,count:pixels.count)
     context.render(result,toBitmap:&sampled,rowBytes:width*16,bounds:image.extent,format:.RGBAf,colorSpace:space)
     return sampled
    }
    let a=try run(rgb,width,1),b=try run(gray,width,1)
    if zip(a,b).allSatisfy({abs($0-$1)<0.00001}) {
     let count=32769,w=257,h=129
     var ramp=[Float](repeating:1,count:w*h*4)
     for i in 0..<(w*h) {
      let encoded = -1+9*Double(min(i,count-1))/Double(count-1)
      let v=encoded < 0 ? -linear(-encoded):linear(encoded)
      for c in 0..<3 {ramp[i*4+c]=v}
     }
     let sampled=try run(ramp,w,h),curve=Array(sampled.prefix(count*4))
     guard curve.allSatisfy({$0.isFinite}),curve.contains(where:{$0>0.5}) else {throw NSError(domain:"灰階曲線檢查失敗",code:1)}
     let file=id+".mono.f32"
     try curve.withUnsafeBytes{try Data($0).write(to:folder.appendingPathComponent(file))}
     metadata["monochromeCurve"]=file
    }
   }
   if metadata["monochromeCurve"] == nil {
    // 用負值、一般色彩與 HDR 實測辨識線性映射，不以配方名稱分支。
    var probe:[Float]=[0,0,0,1,1,0,0,1,0,1,0,1,0,0,1,1]
    for i in 0..<512 {for c in 0..<3 {probe.append(Float((i*(13+c*24))%509)/508*18-2)};probe.append(1)}
    let measured=try sample(probe,probe.count/4,1)
    var affine=[Float]()
    for c in 0..<3 {affine += [measured[4+c]-measured[c],measured[8+c]-measured[c],measured[12+c]-measured[c],measured[c]]}
    var error:Float=0
    for i in 0..<(probe.count/4) {for c in 0..<3 {
     let predicted=probe[i*4]*affine[c*4]+probe[i*4+1]*affine[c*4+1]+probe[i*4+2]*affine[c*4+2]+affine[c*4+3]
     error=max(error,abs(predicted-measured[i*4+c]))
    }}
    if error<0.00002 {metadata["affine"]=affine}
    else {
     var clamped=probe
     for i in 0..<(probe.count/4) {for c in 0..<3 {clamped[i*4+c]=min(1,max(0,probe[i*4+c]))}}
     let bounded=try sample(clamped,probe.count/4,1)
     if zip(measured,bounded).contains(where:{abs($0-$1)>0.00001}) {
      // 中央保留 65 個 sRGB 節點；外側延伸至線性 -1...25，避免曝光／白平衡截斷。
      var encoded=(0..<16).map{-pow(Double(16-$0)/16,2)}
      encoded += (0...64).map{Double($0)/64}
      encoded += (1...48).map{1+3*pow(Double($0)/48,2)}
      let axis=encoded.map{v in v<0 ? -linear(-v):linear(v)},n=axis.count
      let width=n*8,count=n*n*n,height=(count+width-1)/width
      var extended=[Float](repeating:1,count:width*height*4)
      for b in 0..<n {for g in 0..<n {for r in 0..<n {
       let i=((b*n+g)*n+r)*4;extended[i]=axis[r];extended[i+1]=axis[g];extended[i+2]=axis[b]
      }}}
      let sampled=Array(try sample(extended,width,height).prefix(count*4))
      guard sampled.allSatisfy({$0.isFinite}) else {throw NSError(domain:"HDR 色彩表非有限值",code:1)}
      try sampled.withUnsafeBytes{try Data($0).write(to:folder.appendingPathComponent(name))}
      metadata["dimension"]=n;metadata["axis"]=axis
     }
    }
   }
   if !toneCurve.isEmpty {
    let count=32769,w=257,h=129
    var ramp=[Float](repeating:1,count:w*h*4)
    for i in 0..<(w*h) {
     let encoded = -1+9*Double(min(i,count-1))/Double(count-1)
     let v=encoded < 0 ? -linear(-encoded):linear(encoded)
     for c in 0..<3 {ramp[i*4+c]=v}
    }
    let field=CIImage(bitmapData:ramp.withUnsafeBytes{Data($0)},bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:space)
    var curve=[Float](repeating:0,count:ramp.count)
    context.render(field.applyingFilter("CIToneCurve",parameters:toneCurve),toBitmap:&curve,rowBytes:w*16,bounds:field.extent,format:.RGBAf,colorSpace:space)
    let file=id+".output.f32"
    try Array(curve.prefix(count*4)).withUnsafeBytes{try Data($0).write(to:folder.appendingPathComponent(file))}
    metadata["outputCurve"]=file
   }
   if let camera=PhotoCameraProfile.profile(id:id) {
    let fields=Dictionary(uniqueKeysWithValues:Mirror(reflecting:camera).children.compactMap{child in child.label.map{($0,child.value)}})
    var controls=[Double]()
    for name in ["tone","hueGain","hueShift","split"] {
     let values=fields[name] as! [Double]
     controls += name == "hueShift" ? values.map{$0 * .pi / 180}:values
    }
    controls += [1,fields["saturation"] as! Double,camera.isMonochrome ? 1:0,fields["protection"] as! Double]
    metadata["camera"]=controls
   }
   styles.append(metadata)
  }
  try JSONSerialization.data(withJSONObject:["schema":1,"styles":styles],options:[.sortedKeys,.prettyPrinted]).write(to:folder.appendingPathComponent("manifest.json"))
 }
}
'''
source=build/'Export.swift';source.write_text(code)
modules,objects=build_product(root/'PhotoStyleShared',root/'build/swift-tools/shared','PhotoStyleShared')
cmd=['xcrun','swiftc','-O','-parse-as-library','-I',modules,str(source),*objects,'-o',str(build/'export')]
subprocess.run(cmd,check=True);subprocess.run([str(build/'export'),str(output)],check=True)
data=json.loads(manifest.read_text());data['sources']=fingerprint
for style in data['styles']:
 style['sha256']=hashlib.sha256((output/style['file']).read_bytes()).hexdigest()
 if 'outputCurve' in style:style['outputCurveSHA256']=hashlib.sha256((output/style['outputCurve']).read_bytes()).hexdigest()
 if 'monochromeCurve' in style:style['monochromeSHA256']=hashlib.sha256((output/style['monochromeCurve']).read_bytes()).hexdigest()
manifest.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
print('已從 Swift 匯出',len(data['styles']),'個數位／相機風格')
