import CoreImage
import Foundation

/// 文獻啟發的藝術近似；不是片種或藥水的量測校準。
/// 光學 PSF 在乳劑前，紙基 PSF 僅在光學印相後。兩者不以亮部門檻代替 MTF。
public enum PhotoFilmMaterialProcessor {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let combine = CIColorKernel(source: """
    kernel vec4 materialPSF(__sample src, __sample r, __sample g, __sample b, float amount) {
        return vec4(mix(src.rgb, vec3(r.r,g.g,b.b),amount), src.a);
    }
    """)
    private static let paperWhite = CIColorKernel(source: """
    kernel vec4 paperWhite(__sample src, vec3 white) { return vec4(src.rgb*white,src.a); }
    """)

    public static func emulsion(to image: CIImage, effects: PhotoFilmEffects, strength: Double) -> CIImage {
        let e = effects.clamped(), amount = e.emulsionMTF / 100 * min(1,max(0,strength))
        guard amount > 0, let linear = image.matchedFromWorkingSpace(to: space) else { return image }
        let scale = max(image.extent.width,image.extent.height)/3000 * 36/e.filmWidthMM
        // Gaussian-mixture PSF：RGB 分層的散射距離不同；控制量兼顧窄核與寬尾。
        func blur(_ radius: Double) -> CIImage {
            linear.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius*scale]).cropped(to:image.extent)
        }
        guard let result = combine?.apply(extent:image.extent,arguments:[linear,blur(1.8),blur(1.2),blur(0.8),amount]) else { return image }
        return (result.matchedToWorkingSpace(from:space) ?? image).cropped(to:image.extent)
    }

    static func printMaterial(to image: CIImage, effects: PhotoFilmEffects, stock: PhotoFilmStock) -> CIImage {
        let e=effects.clamped()
        guard e.scannerProfile == .off, stock.family != "reversal",
              e.paperScatter > 0 || e.paperWhite != 100 || e.paperProfile == .warmFiber,
              let linear=image.matchedFromWorkingSpace(to:space) else { return image }
        let radius=max(image.extent.width,image.extent.height)/3000 * 2.5 * e.paperScatter/100
        var result=linear
        if radius>0 { result=linear.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:image.extent) }
        let warm=e.paperProfile == .warmFiber
        let white=CIVector(x:e.paperWhite/100,y:e.paperWhite/100*(warm ? 0.975:1),z:e.paperWhite/100*(warm ? 0.91:1))
        result=paperWhite?.apply(extent:image.extent,arguments:[result,white]) ?? result
        return (result.matchedToWorkingSpace(from:space) ?? image).cropped(to:image.extent)
    }

    /// 獨立感色層曲線。以每層的中灰密度作基準，避免只有不必要的全圖色偏。
    static func layerCurves(_ p: PhotoFilmSpectralProfile, amount: Double) -> [SIMD4<Double>] {
        let a = p.monochrome ? 0 : min(1,max(0,amount/100))
        let signature = p.stock.family == "reversal" ? 1.35 : (p.stock.family == "cinema" ? 0.65 : 1)
        return (0..<3).map { c in
            let toe=[-0.20,0.04,0.24][c]*signature*a
            let shoulder=[-0.25,0.08,0.32][c]*signature*a
            let bend=[-0.07,0.025,0.09][c]*signature*a
            return .init(p.toe+toe,p.shoulder+shoulder,p.bend*(1+bend),p.maxDensity)
        }
    }

    static func paper(_ p: PhotoFilmSpectralProfile, effects e: PhotoFilmEffects) -> SIMD4<Double> {
        var slope=p.printSlope, maximum=p.printMaxDensity
        if e.scannerProfile == .off && !p.reversal {
            switch e.paperProfile {
            case .reference: break
            case .glossy: slope=1.12; maximum=2.8
            case .matte: slope=0.88; maximum=2.05
            case .warmFiber: slope=0.96; maximum=2.3
            }
            maximum=min(4,max(1,maximum+e.paperDensityOffset))
        }
        let ratio = -log10(0.18)/maximum
        return .init(slope,maximum,log(ratio/(1-ratio)),p.retainedSilver)
    }

    static func reciprocityLoss(_ p: PhotoFilmSpectralProfile, effects e: PhotoFilmEffects) -> SIMD3<Double> {
        let t=e.exposureSeconds
        let long=max(0,log2(max(1,t))), short=max(0,log2(0.001/max(t,0.0001)))
        let amount=e.reciprocityAmount/100
        let base=amount*(0.12*long+0.05*short)
        // 分層失效係數是明示的藝術先驗；沒有從數位照片快門反推底片。
        return p.monochrome ? .init(repeating:base) : .init(base*1.12,base,base*1.28)
    }
}
