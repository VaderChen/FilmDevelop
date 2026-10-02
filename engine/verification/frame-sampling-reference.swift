// 擷取 Swift／AppKit 浮點框圖的通用平移核心；不使用照片、配方或機型特例。
// 3 組正交色碼量測 3×3 線性核心，涵蓋畫面內部及八種影像邊界。
import AppKit
import Foundation
let space=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
let flags=CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.floatComponents.rawValue|CGBitmapInfo.byteOrder32Little.rawValue
let w=9,h=9,canvas=16
var images=[NSImage]()
for group in 0..<3 {
 let source=CGContext(data:nil,width:w,height:h,bitsPerComponent:32,bytesPerRow:w*16,space:space,bitmapInfo:flags)!
 let p=source.data!.assumingMemoryBound(to:Float.self)
 for y in 0..<h {for x in 0..<w {
  let i=(y*w+x)*4,code=(y%3)*3+x%3
  for c in 0..<3 {p[i+c] = code==group*3+c ? 1:0};p[i+3]=1
 }}
 images.append(NSImage(cgImage:source.makeImage()!,size:CGSize(width:w,height:h)))
}
let context=CGContext(data:nil,width:canvas,height:canvas,bitsPerComponent:32,bytesPerRow:canvas*16,space:space,bitmapInfo:flags)!
context.translateBy(x:0,y:CGFloat(canvas));context.scaleBy(x:1,y:-1)
var table=[Float]();table.reserveCapacity(256*256*9*9)
for fy in 0..<256 {
 for fx in 0..<256 {autoreleasepool {
  var values=[[Float]](repeating:[Float](repeating:0,count:9),count:9),coverage=[Float](repeating:0,count:9)
  for group in 0..<3 {
   context.clear(CGRect(x:0,y:0,width:canvas,height:canvas))
   NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:true)
   images[group].draw(in:CGRect(x:2+Double(fx)/256,y:2+Double(fy)/256,width:Double(w),height:Double(h)),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
   NSGraphicsContext.restoreGraphicsState()
   let p=context.data!.assumingMemoryBound(to:Float.self)
   for (cy,iy) in [4,0,h].enumerated() {for (cx,ix) in [4,0,w].enumerated() {
    let i=((iy+2)*canvas+ix+2)*4,profile=cy*3+cx
    coverage[profile]=p[i+3]
    for c in 0..<3 {values[profile][group*3+c]=p[i+c]}
   }}
  }
  for (cy,iy) in [4,0,h].enumerated() {for (cx,ix) in [4,0,w].enumerated() {
   let profile=cy*3+cx,alpha=coverage[profile],bx=min(w-2,max(1,ix)),by=min(h-2,max(1,iy))
   var kernel=[Float]()
   for dy in -1...1 {for dx in -1...1 {
    kernel.append(alpha>0 ? max(0,values[profile][((by+dy)%3)*3+(bx+dx)%3]/alpha):0)
   }}
   if alpha>0 {
    let total=kernel.reduce(0,+)
    precondition(abs(total-1)<0.00001,"取樣核心未保持能量")
    kernel=kernel.map{$0/total}
   } else {kernel[(min(h-1,iy)-by+1)*3+min(w-1,ix)-bx+1]=1}
   table.append(contentsOf:kernel)
  }}
 }}
 if fy%64==0 {print("已擷取相位列 \(fy)/256");fflush(stdout)}
}
try table.withUnsafeBytes {try Data($0).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
