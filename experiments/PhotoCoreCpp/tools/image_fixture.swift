import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import PhotoStyleShared

// 僅用於 macOS 驗證／產生跨平台 fixture，不會連結進 C++ 執行檔。
@main struct ImageFixture {
 static func main() throws {
  guard CommandLine.arguments.count==4 else {fatalError("用法：image-fixture 照片 輸入.pfm Swift曝光參考.pfm")}
  let url=URL(fileURLWithPath:CommandLine.arguments[1]);let data=try Data(contentsOf:url)
  let image:CIImage
  if let raw=PhotoRAWDecoder.makeSceneLinearFilter(data:data,identifierHint:UTType(filenameExtension:url.pathExtension)?.identifier),let decoded=raw.outputImage {image=decoded}
  else if let decoded=CIImage(data:data,options:[.applyOrientationProperty:true]) {image=decoded}
  else {fatalError("無法讀取影像")}
  let scale=min(1,768/max(image.extent.width,image.extent.height));let transformed=image.clampedToExtent().transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY)).transformed(by:CGAffineTransform(scaleX:scale,y:scale))
  let width=Int(image.extent.width*scale),height=Int(image.extent.height*scale)
  let bounds=CGRect(x:0,y:0,width:width,height:height)
  let cs=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
  let context=CIContext(options:[.workingColorSpace:cs,.outputColorSpace:cs,.workingFormat:CIFormat.RGBAf])
  var pixels=[Float](repeating:0,count:width*height*4)
  context.render(transformed,toBitmap:&pixels,rowBytes:width*16,bounds:bounds,format:.RGBAf,colorSpace:cs)
  // 將浮點輸入固定後才計算 Swift 參考，避免兩次取樣差異混入演算法比較。
  let bytes=pixels.withUnsafeBytes{Data($0)}
  let fixed=CIImage(bitmapData:bytes,bytesPerRow:width*16,size:bounds.size,format:.RGBAf,colorSpace:cs)
  var expected=[Float](repeating:0,count:pixels.count)
  context.render(PhotoExposureProcessor.apply(to:fixed,ev:0.7),toBitmap:&expected,rowBytes:width*16,bounds:bounds,format:.RGBAf,colorSpace:cs)
  func write(_ samples:[Float],_ path:String) throws {
   var out=Data("PF\n\(width) \(height)\n-1.0\n".utf8)
   // Core Image bitmap 由頂列開始；PFM 檔案須改成底列先存。
   for y in (0..<height).reversed() { for x in 0..<width {
    let i = y*width+x
    guard abs(samples[i*4+3]-1)<1e-5 else {fatalError("fixture 要求不透明照片：alpha=\(samples[i*4+3])")}
    for c in 0..<3 {var bits=samples[i*4+c].bitPattern.littleEndian;withUnsafeBytes(of:&bits){out.append(contentsOf:$0)}}
   }
   }
   try out.write(to:URL(fileURLWithPath:path))
  }
  try write(pixels,CommandLine.arguments[2]);try write(expected,CommandLine.arguments[3])
  print("已產生 \(width)×\(height) 線性照片與 +0.7 EV 參考")
 }
}
