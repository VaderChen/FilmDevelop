import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import simd

// 與 Shared 原始碼一起編譯的離線工具；C++ 執行期不載入 Swift／Core Image。
@main enum FilmReference {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [.workingColorSpace: linear, .outputColorSpace: linear, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    static func v(_ x: SIMD3<Double>) -> [Double] { [x.x,x.y,x.z] }
    static func rows(_ m: simd_double3x3) -> [[Double]] { (0..<3).map { [m.columns.0[$0],m.columns.1[$0],m.columns.2[$0]] } }
    static func object<T: Encodable>(_ x: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(x)) }
    static func save(_ x: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject:x,options:[.sortedKeys,.prettyPrinted]).write(to:url) }
    static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func export(_ root: URL) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let lights = PhotoFilmEffects.Illuminant.allCases
        var profiles: [String:Any] = [:]
        for p in PhotoFilmSpectralProfile.all {
            var item: [String:Any] = ["monochrome":p.monochrome,"reversal":p.reversal,"family":p.stock.family,
                "curve":[p.toe,p.shoulder,p.bend,p.maxDensity],"paper":[p.printSlope,p.printMaxDensity,p.printBias,p.retainedSilver],
                "shift":p.reversalShift,"middleDensity":p.density(0),"scannerChroma":p.scannerChroma,
                "gain":v(p.layerGain),"ev":v(p.layerEV),"sensitivity":p.sensitivity.map(v),"negativeDyes":p.negativeDyes.map(v),
                "printSensitivity":p.printSensitivity.map(v),"printDyes":p.printDyes.map(v),"baseDensity":p.baseDensity,
                "referencePrintExposure":v(p.referencePrintExposure),"defaults":try object(p.stock.defaultEffects)]
            var calibrations:[String:Any] = [:]
            for light in lights {
                let cal=PhotoFilmScanner.calibration(p,light:PhotoFilmIllumination.spectrum(light,wavelengths:PhotoFilmSpectralProfile.wavelengths))
                calibrations[light.rawValue]=["base":v(cal.base),"middle":v(cal.middle),"inverse":rows(cal.inverse),"slope":cal.slope]
            }
            item["calibrations"]=calibrations
            if let (tone,palette)=PhotoFilmCharacterProcessor.recipe(p.stock) {
                item["character"]=[tone.x,tone.y,palette.x,palette.y,palette.z,palette.w]
            }
            profiles[p.stock.rawValue]=item
        }
        var spectra:[String:Any]=[:], matrices:[String:Any]=[:]
        for light in lights {
            let spectrum=PhotoFilmIllumination.spectrum(light,wavelengths:PhotoFilmSpectralProfile.wavelengths)
            spectra[light.rawValue]=spectrum
            var response=simd_double3x3(columns:(.zero,.zero,.zero))
            for k in 0..<13 {
                let sensor=PhotoFilmSpectralProfile.scanner[k]*spectrum[k], basis=PhotoFilmSpectralProfile.inputBasis[k]
                response.columns.0 += sensor*basis.x; response.columns.1 += sensor*basis.y; response.columns.2 += sensor*basis.z
            }
            let matrix=light == .reference ? matrix_identity_double3x3 : PhotoFilmSpectralProfile.scannerToRGB*response
            matrices[light.rawValue]=["forward":rows(matrix),"inverse":rows(matrix.inverse)]
        }
        var filters:[String:Any]=[:], scanners:[String:Any]=[:]
        for filter in PhotoFilmEffects.MonochromeFilter.allCases { filters[filter.rawValue]=PhotoFilmSpectralProfile.wavelengths.map { PhotoFilmSpectralProfile.filterTransmission(filter,wavelength:$0) } }
        for profile in PhotoFilmEffects.ScannerProfile.allCases {
            let s=profile.rendering,w=profile.warmth
            scanners[profile.rawValue]=["rendering":[s.x,s.y,s.z,s.w],"warmth":[w.x,w.y]]
        }
        try save(["schema":1,"dimension":PhotoFilmSpectralTable.dimension,"profiles":profiles,"lights":spectra,"lightMatrices":matrices,
            "filters":filters,"scanners":scanners,"scanner":PhotoFilmSpectralProfile.scanner.map(v),"scannerToRGB":rows(PhotoFilmSpectralProfile.scannerToRGB),
            "table_sha256":hash(PhotoFilmSpectralTable.data),"provenance":PhotoFilmSpectralProfile.provenance],root.appendingPathComponent("film-profiles.json"))
        try PhotoFilmSpectralTable.data.write(to:root.appendingPathComponent("spectral-table.f32"))
        print("已匯出 \(profiles.count) 種底片常數、光源、掃描器校準與 FP32 光譜表")
    }
    static func readPFM(_ url:URL) throws -> CIImage {
        let data=try Data(contentsOf:url); var offset=0
        func line()->String { let start=offset; while offset<data.count && data[offset] != 10 { offset+=1 }; let s=String(data:data[start..<offset],encoding:.utf8)!;offset+=1;return s }
        guard line()=="PF" else { throw NSError(domain:"PFM 格式",code:1) }
        let dims=line().split(separator:" ").map { Int($0)! }; let w=dims[0],h=dims[1]
        guard line()=="-1.0", data.count-offset == w*h*12 else { throw NSError(domain:"PFM 長度",code:1) }
        var pixels=[Float](repeating:1,count:w*h*4)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            let index=offset+((h-1-y)*w+x)*12+c*4
            pixels[(y*w+x)*4+c]=Float(bitPattern:UInt32(littleEndian:data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset:index,as:UInt32.self) }))
        }}}
        return CIImage(bitmapData:pixels.withUnsafeBytes { Data($0) },bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:linear)
    }
    static func snapshot(_ image:CIImage) throws -> CIImage {
        guard let bitmap=context.createCGImage(image,from:image.extent,format:.RGBAf,colorSpace:linear,deferred:false) else { throw NSError(domain:"浮點成品",code:1) }
        return CIImage(cgImage:bitmap)
    }
    static func pfm(_ image:CIImage,_ url:URL) throws -> String {
        let rect=image.extent.integral,w=Int(rect.width),h=Int(rect.height)
        var p=[Float](repeating:0,count:w*h*4)
        context.render(image,toBitmap:&p,rowBytes:w*16,bounds:rect,format:.RGBAf,colorSpace:linear)
        var data=Data("PF\n\(w) \(h)\n-1.0\n".utf8)
        for y in (0..<h).reversed() { for x in 0..<w { for c in 0..<3 {
            let v=p[(y*w+x)*4+c]; guard v.isFinite else { throw NSError(domain:"非有限值",code:1) }
            var bits=v.bitPattern.littleEndian;withUnsafeBytes(of:&bits) { data.append(contentsOf:$0) }
        }}}
        try data.write(to:url);return hash(data)
    }
    static func debugField(_ image:CIImage,_ name:String) {
        guard let path=ProcessInfo.processInfo.environment["PHOTOCORE_FILM_TRACE"] else { return }
        do { let folder=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            _ = try pfm(image,folder.appendingPathComponent(name+".pfm"))
        } catch { fputs("顯影診斷寫入失敗：\(error)\n",stderr);exit(1) }
    }
    static func fixtures(_ root:URL,_ files:[String]) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let manifest=root.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath:manifest.path) { try FileManager.default.removeItem(at:manifest) }
        var cases:[[String:Any]]=[]
        guard PhotoFilmDevelopmentProcessor.kernelsAreAvailable, PhotoFilmSpectralProcessor.kernelIsAvailable,
              PhotoPositiveScannerProcessor.kernelIsAvailable else { throw NSError(domain:"參考 GPU 核心不可用",code:1) }
        for (index,file) in files.enumerated() {
            let source=try readPFM(URL(fileURLWithPath:file))
            let input="input-\(index).pfm",inputHash=try pfm(source,root.appendingPathComponent(input))
            let selectedStocks=ProcessInfo.processInfo.environment["PHOTOCORE_FILM_STOCKS"]?.split(separator:",").map(String.init)
            let selectedVariants=ProcessInfo.processInfo.environment["PHOTOCORE_FILM_VARIANTS"]?.split(separator:",").map(String.init)
            let variants=["default","development","scanner","paper","lights","silver","exposure","faded","paper-glossy","zero-strength"]
            if let selectedStocks, selectedStocks.isEmpty || !selectedStocks.allSatisfy({ PhotoFilmStock(rawValue:$0) != nil }) { throw NSError(domain:"未知片種篩選",code:1) }
            if let selectedVariants, selectedVariants.isEmpty || !selectedVariants.allSatisfy({ variants.contains($0) }) { throw NSError(domain:"未知參數篩選",code:1) }
            for stock in PhotoFilmStock.allCases where selectedStocks == nil || selectedStocks!.contains(stock.rawValue) {
                for variant in variants where selectedVariants == nil || selectedVariants!.contains(variant) {
                    try autoreleasepool {
                        var e=stock.defaultEffects
                        var strength=1.0
                        switch variant {
                        case "development": e.developmentAmount=80;e.developmentTime=85;e.developmentDiffusion=0.6;e.developmentAgitation=15;e.developerTemperature=28;e.developerActivity=140
                        case "scanner": e.scannerProfile = .frontierSP500;e.scannerIlluminant = .blackbody5500;e.scanSaturation=65;e.scanDensityCorrection=55;e.scanFlare=30;e.scanMidtoneWarmth = -15;e.scanHighlightWarmth=20
                        case "paper": e.scannerSource = .paper;e.paperProfile = .warmFiber;e.paperScatter=35;e.paperWhite=94;e.paperDensityOffset = -0.2
                        case "lights": e.printIlluminant = .blackbody4000;e.viewIlluminant = .blackbody7500;e.scannerIlluminant = .blackbody3200;e.scannerProfile = .off;e.monochromeFilter = .red;e.monochromeFilterStrength=80
                        case "exposure": e.printExposure=0.7;e.printExposureHighlights = -0.3;e.printExposureMidtones=0.5;e.printExposureShadows=1.2;e.printContrast=80
                        case "faded": e.scannerProfile = .fadedVintage;e.scanDensityCorrection=0;e.scanSaturation=80;e.scanFlare=50;e.printIlluminant = .blackbody5000
                        case "paper-glossy": e.scannerSource = .paper;e.paperProfile = .glossy;e.paperDensityOffset=0.7;e.paperScatter=100;e.paperWhite=80;e.scannerProfile = .coolscan9000
                        case "zero-strength": strength=0;e.scannerProfile = .softPortrait
                        case "silver": e.silverRetention=20;e.reciprocityAmount=35;e.exposureSeconds=12;e.layerResponse=50;e.couplerAmount=40;e.couplerRadius=0.5;strength=0.6
                        default: break
                        }
                        let id="image-\(index)-\(stock.rawValue)-\(variant)"
                        // 三個模組串接的整張成品；沒有用中途的 Swift 圖片餵 C++。
                        let developed=try snapshot(PhotoFilmDevelopmentProcessor.apply(to:source,effects:e,strength:strength))
                        let chemistry=try snapshot(PhotoDeveloperChemistryProcessor.apply(to:developed,settings:e.developerChemistry,strength:strength,monochrome:stock.isMonochrome))
                        let film=try snapshot(PhotoFilmStockProcessor.apply(to:chemistry,stock:stock,effects:e,strength:strength,deferScannerRendering:true))
                        let character=try snapshot(PhotoFilmCharacterProcessor.apply(to:film,stock:stock))
                        var scan=e
                        if scan.scannerProfile == .off { scan.scannerProfile = .neutral }
                        if scan.scannerSource == .film || stock.family == "reversal" { scan.scanFlare=0 }
                        var scanned=PhotoPositiveScannerProcessor.apply(to:character,effects:scan)
                        if stock.isMonochrome { scanned=PhotoImageEffectsProcessor.monochrome(scanned,profile:.desaturate) }
                        let finished=try snapshot(scanned)
                        guard let png=context.pngRepresentation(of:finished,format:.RGBA16,colorSpace:srgb,options:[:]),let exported=CIImage(data:png) else { throw NSError(domain:"PNG16 匯出",code:1) }
                        try png.write(to:root.appendingPathComponent(id+".png"))
                        let ref=id+".pfm",refHash=try pfm(exported,root.appendingPathComponent(ref))
                        // 階段快照僅供定位，驗收始終比對最後一張成品。
                        for (stage,image) in [("development",developed),("chemistry",chemistry),("spectral",film),("character",character),("scanner",finished)] {
                            _ = try pfm(image,root.appendingPathComponent(id+"-"+stage+".pfm"))
                        }
                        let recipe=id+".json"
                        try save(["schema":1,"scope":"film-development-scanner","style":stock.rawValue,"effects":try object(e),"strength":strength,"isPreview":false],root.appendingPathComponent(recipe))
                        cases.append(["id":id,"input":input,"input_sha256":inputHash,"recipe":recipe,"recipe_sha256":hash(try Data(contentsOf:root.appendingPathComponent(recipe))),"reference":ref,"reference_sha256":refHash])
                        print("底片／顯影／掃描參考：\(id)")
                    }
                }
            }
        }
        try save(["schema":1,"scope":"film-development-scanner","metric":"CIEDE2000","aggregation":"max","threshold":2,"cases":cases,
            "coverage_notes":"這是此次三模組連續流程；不等於 App 全流程驗收，未包含前置乳劑、AI、使用者色調與裁切等模組。"],manifest)
    }
    static func main() {
        do {
            let a=CommandLine.arguments
            guard a.count>=3 else { throw NSError(domain:"用法：film-reference export 資料夾；fixtures 資料夾 input.pfm...",code:1) }
            let root=URL(fileURLWithPath:a[2])
            if a[1]=="export" { try export(root) }
            else if a[1]=="fixtures",a.count>3 { try fixtures(root,Array(a.dropFirst(3))) }
            else { throw NSError(domain:"無效指令",code:1) }
        } catch { fputs("參考工具失敗：\(error)\n",stderr);exit(1) }
    }
}
