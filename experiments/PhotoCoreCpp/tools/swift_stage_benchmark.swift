import Foundation
import CoreImage
import Metal
import CryptoKit

// 直接與未修改的 Shared 原始碼以 -O 編譯。所有計時皆同步 render 到 CPU RGBAf。
@main enum SwiftStageBenchmark {
    struct Recipe: Decodable { var schema:Int; var scope:String; var style:String; var effects:PhotoFilmEffects; var strength:Double; var isPreview:Bool }
    static let linear=CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    static func fail(_ message:String)->NSError { NSError(domain:message,code:1) }
    static func read(_ path:String)throws->(Data,Int,Int){
        let data=try Data(contentsOf:URL(fileURLWithPath:path));var offset=0
        func line()throws->String{let start=offset;while offset<data.count && data[offset] != 10{offset+=1};guard offset<data.count,let text=String(data:data[start..<offset],encoding:.utf8) else{throw fail("PFM 標頭不完整")};offset+=1;return text}
        guard try line()=="PF" else{throw fail("須為 RGB PFM")}
        let dimensions=try line().split(separator:" ").compactMap{Int($0)}
        guard dimensions.count==2,dimensions[0]>0,dimensions[1]>0 else{throw fail("PFM 尺寸不符")}
        let w=dimensions[0],h=dimensions[1]
        guard try line()=="-1.0",data.count-offset==w*h*12 else{throw fail("PFM 必須為 little endian，長度須完整")}
        var rgba=[Float](repeating:1,count:w*h*4)
        data.withUnsafeBytes { raw in
            for y in 0..<h { for x in 0..<w {for c in 0..<3{
                let bits=raw.loadUnaligned(fromByteOffset:offset+((h-1-y)*w+x)*12+c*4,as:UInt32.self)
                rgba[(y*w+x)*4+c]=Float(bitPattern:UInt32(littleEndian:bits))
            }}}
        }
        guard rgba.allSatisfy(\.isFinite) else{throw fail("來源含非有限值")}
        return (rgba.withUnsafeBytes{Data($0)},w,h)
    }
    static func write(_ pixels:[Float],_ w:Int,_ h:Int,_ path:String)throws{
        guard pixels.allSatisfy(\.isFinite) else{throw fail("成品含非有限值")}
        var rgb=[Float](repeating:0,count:w*h*3)
        for y in 0..<h {for x in 0..<w {for c in 0..<3{rgb[((h-1-y)*w+x)*3+c]=pixels[(y*w+x)*4+c]}}}
        var data=Data("PF\n\(w) \(h)\n-1.0\n".utf8);rgb.withUnsafeBytes{data.append(contentsOf:$0)}
        try data.write(to:URL(fileURLWithPath:path))
    }
    static func main(){
        do{
            let args=CommandLine.arguments
            guard args.count==7 else{throw fail("用法：swift-stage-benchmark input.pfm recipe.json development|spectral output.pfm report.json repeats")}
            guard !FileManager.default.fileExists(atPath:args[4]),!FileManager.default.fileExists(atPath:args[5]) else{throw fail("請使用全新輸出路徑")}
            guard ["development","spectral"].contains(args[3]),let repeats=Int(args[6]),(1...15).contains(repeats) else{throw fail("階段或重複次數不符")}
            let recipe=try JSONDecoder().decode(Recipe.self,from:Data(contentsOf:URL(fileURLWithPath:args[2])))
            guard recipe.schema==1,recipe.scope=="film-development-scanner",recipe.isPreview==false,let stock=PhotoFilmStock(rawValue:recipe.style) else{throw fail("配方契約不符")}
            let (data,w,h)=try read(args[1])
            guard let device=MTLCreateSystemDefaultDevice() else{throw fail("沒有 Metal GPU")}
            let start=DispatchTime.now().uptimeNanoseconds
            let context=CIContext(mtlDevice:device,options:[.workingColorSpace:linear,.outputColorSpace:linear,.workingFormat:CIFormat.RGBAf,.cacheIntermediates:false,.useSoftwareRenderer:false])
            let initMS=Double(DispatchTime.now().uptimeNanoseconds-start)/1e6
            // 不在計時前觸發 static kernel 編譯：第一輪會保留此成本，後續取暖機中位數。
            var times=[Double](),outputs=[Float](),checksums=[String]();var firstMS=0.0
            for trial in 0...repeats {
                try autoreleasepool {
                    let begin=DispatchTime.now().uptimeNanoseconds
                    let input=CIImage(bitmapData:data,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:linear)
                    let result:CIImage
                    if args[3]=="development" { result=PhotoFilmDevelopmentProcessor.apply(to:input,effects:recipe.effects,strength:recipe.strength) }
                    else{result=PhotoFilmSpectralProcessor.apply(to:input,stock:stock,effects:recipe.effects,strength:recipe.strength,deferScannerRendering:true)}
                    guard result !== input else{throw fail("Swift 階段回退為原圖")}
                    var pixels=[Float](repeating:0,count:w*h*4)
                    context.render(result,toBitmap:&pixels,rowBytes:w*16,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBAf,colorSpace:linear)
                    let elapsed=Double(DispatchTime.now().uptimeNanoseconds-begin)/1e6
                    guard pixels.allSatisfy(\.isFinite) else{throw fail("Swift 成品含非有限值")}
                    let hash=pixels.withUnsafeBytes{SHA256.hash(data:Data($0)).map{String(format:"%02x",$0)}.joined()}
                    checksums.append(hash)
                    if trial==0{firstMS=elapsed}else{times.append(elapsed)}
                    if trial==repeats{outputs=pixels}
                }
            }
            guard PhotoFilmDevelopmentProcessor.kernelsAreAvailable,PhotoFilmSpectralProcessor.kernelIsAvailable else{throw fail("Swift 核心缺件")}
            guard Set(checksums).count==1 else{throw fail("相同輸入重複結果不一致")}
            try write(outputs,w,h,args[4])
            let report:[String:Any] = ["schema":1,"backend":"swift-coreimage-metal","device":device.name,"stage":args[3],"width":w,"height":h,"init_ms":initMS,"first_ms":firstMS,"runs_ms":times,"median_ms":times.sorted()[times.count/2],"deterministic":true,"output_rgba_sha256":checksums.last!,"cache_intermediates":false,"scope":"相同 CPU 輸入 → 單一原始階段 → 同步 CPU RGBAf 回讀；不含 PFM I/O、配方解析與成品 SHA-256"]
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:args[5]))
            print("Swift \(args[3]) \(w)×\(h)：\(times.sorted()[times.count/2]) ms")
        }catch{fputs("Swift 階段量測失敗：\(error)\n",stderr);exit(1)}
    }
}
