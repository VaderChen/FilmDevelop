import Foundation
import CoreImage
import ImageIO
let context=CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!, .workingFormat:CIFormat.RGBAf])
let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
let sourceMode=CommandLine.arguments.dropFirst().first == "--source"
for path in CommandLine.arguments.dropFirst(sourceMode ? 2 : 1) {
 let url=URL(fileURLWithPath:path)
 let image:CIImage
 if sourceMode {
  // 計算比對必須使用與 Swift PhotoImage.floatingBitmap 相同的解碼像素。
  // CGContext 與直接 CIImage 的 ICC／精度路徑不同，極暗像素經銳化會放大差異。
  let source=CGImageSourceCreateWithURL(url as CFURL,nil)!
  let bitmap=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldAllowFloat:true] as CFDictionary)!
  let working=bitmap.colorSpace.flatMap { $0.model == .rgb ? CGColorSpaceCreateExtendedLinearized($0):nil } ?? space
  let buffer=CGContext(data:nil,width:bitmap.width,height:bitmap.height,bitsPerComponent:32,bytesPerRow:0,space:working,
    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.floatComponents.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
  buffer.setBlendMode(.copy);buffer.draw(bitmap,in:CGRect(x:0,y:0,width:bitmap.width,height:bitmap.height))
  image=CIImage(cgImage:buffer.makeImage()!)
 } else {image=CIImage(contentsOf:url)!}
 let w=Int(image.extent.width),h=Int(image.extent.height)
 var values=[Float](repeating:0,count:w*h*4)
 context.render(image,toBitmap:&values,rowBytes:w*16,bounds:image.extent,format:.RGBAf,colorSpace:space)
 var rgb=[Float]();rgb.reserveCapacity(w*h*3)
 for y in (0..<h).reversed() { for x in 0..<w { let i=(y*w+x)*4;rgb.append(contentsOf:values[i..<i+3]) } }
 var data=Data("PF\n\(w) \(h)\n-1.0\n".utf8);rgb.withUnsafeBytes{data.append(contentsOf:$0)}
 try data.write(to:url.deletingPathExtension().appendingPathExtension("pfm"))
}
