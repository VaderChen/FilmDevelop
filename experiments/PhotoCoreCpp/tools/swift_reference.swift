import Foundation
import CoreImage
import PhotoStyleShared

// 與專案現有 Swift 檔案一同編譯：直接呼叫原公式，不複製參考公式。
@main struct Reference {
 static func main() throws {
  let output=URL(fileURLWithPath:CommandLine.arguments[1]);var lines=["# 由現有 Swift CPU 與 Core Image 實作產生；不得手動修改期望值。"]
  func emit(_ op:String,_ values:[Double]) { lines.append(op+" "+values.map{String($0)}.joined(separator:" ")) }
  for i in 0..<1500 {
   let z=SIMD3<Double>(Double((i*17)%65)-32,Double((i*31)%65)-32,Double((i*47)%65)-32)
   let c=PhotoExposureProtection.curveParameters(zones:z)
   emit("curve",[z.x,z.y,z.z,c.x,c.y,c.z])
   let y=exp2(Double(i%161)/8-16)*0.18
   emit("zone",[y,c.x,c.y,c.z,PhotoExposureProtection.exposureEV(luminance:y,curve:c)])
   let gain=exp2(Double(i%129)/8-8)
   emit("peak",[y,gain,PhotoExposureProtection.peak(y,gain:gain)])
   let rgb=SIMD3<Double>(Double(i%79)/13-0.2,Double(i%53)/23,Double(i%97)/19)
   let lab=PhotoExposureColor.lab(rgb);emit("lab",[rgb.x,rgb.y,rgb.z,lab.x,lab.y,lab.z])
   let slider=Double(i%301)-150;emit("slider",[slider,PhotoExposureScale.ev(fromSlider:slider)])
   let alpha=Float([0.0,0.25,0.7,1.0][i%4]);let p=[Float(rgb.x)*alpha,Float(rgb.y)*alpha,Float(rgb.z)*alpha,alpha]
   let zones=SIMD3<Double>(Double(i%33)-16,Double((i*3)%33)-16,Double((i*7)%33)-16)
   let global=Double(i%9)-4,amount=Double(i%5)/4,protect=i%2==0,peak=i%3==0
   var expected=p
   if alpha>0 && zones != .zero && amount>0 {
    let x=SIMD3<Double>(Double(p[0]/alpha),Double(p[1]/alpha),Double(p[2]/alpha))
    let local=PhotoExposureProtection.exposureEV(x,zones:zones-SIMD3(repeating:global))
    let gain=PhotoExposureProtection.luminanceGain(x,gain:exp2(global+local),protectsHighlights:protect,protectsPeak:peak)
    for j in 0..<3 {expected[j]=Float(Double(p[j])*(1+(gain-1)*amount))}
   }
   emit("exposure",p.map(Double.init)+[zones.x,zones.y,zones.z,global,amount,protect ? 1:0,peak ? 1:0]+expected.map(Double.init))
  }
  let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
  let context=CIContext(options:[.workingColorSpace:space,.outputColorSpace:space,.workingFormat:CIFormat.RGBAf,.cacheIntermediates:false])
  let width=257
  var samples=[Float]();for i in 0..<width {let v=Float(exp2(Double(i)/16-12));let a:Float=i%4==0 ? 0.5:1;samples += [v*a,(i%7==0 ? -v*0.1:v*0.6)*a,v*0.3*a,a]}
  let bytes=samples.withUnsafeBytes{Data($0)}
  let image=CIImage(bitmapData:bytes,bytesPerRow:width*16,size:CGSize(width:width,height:1),format:.RGBAf,colorSpace:space)
  func rendered(_ image:CIImage)->[Float] {var out=[Float](repeating:0,count:width*4);context.render(image,toBitmap:&out,rowBytes:width*16,bounds:CGRect(x:0,y:0,width:width,height:1),format:.RGBAf,colorSpace:space);return out}
  for ev in [-2.0,-0.5,0,0.5,2.0] {
   let result=rendered(PhotoStyleShared.PhotoExposureProcessor.apply(to:image,ev:ev))
   for i in 0..<width {emit("gpu",Array(samples[i*4..<i*4+4]).map(Double.init)+[ev,ev,ev,0,1,0,0]+Array(result[i*4..<i*4+4]).map(Double.init))}
  }
  let raw=rendered(PhotoStyleShared.PhotoRAWDynamicRangeProcessor.prepareForDisplayAdjustments(image))
  for i in 0..<width {emit("raw",Array(samples[i*4..<i*4+4]).map(Double.init)+Array(raw[i*4..<i*4+4]).map(Double.init))}
  let rows=[[1.02,-0.01,0,0.01,0,0],[0.01,0.98,0,0,0.02,0],[0,0,1.03,0,-0.01,0.01]]
  let calibration=try PhotoStyleShared.PhotoColorCalibration(name:"測試",provenance:"獨立 C++ 比對",stage:.input,rows:rows)
  let calibrated=rendered(PhotoStyleShared.PhotoColorCalibrationProcessor.apply(to:image,calibration:calibration))
  for i in 0..<width {emit("calibration",Array(samples[i*4..<i*4+4]).map(Double.init)+rows.flatMap{$0}+Array(calibrated[i*4..<i*4+4]).map(Double.init))}
  try (lines.joined(separator:"\n")+"\n").write(to:output,atomically:true,encoding:.utf8)
  print("產生 \(lines.count-1) 筆 Swift／Core Image 參考資料")
 }
}
