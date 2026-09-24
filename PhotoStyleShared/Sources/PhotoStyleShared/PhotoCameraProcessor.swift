import CoreImage
import Foundation

/// 依相機影像控制方向設計的獨立近似，並非原廠 LUT 或感光元件校準。
public struct PhotoCameraProfile: Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let isMonochrome: Bool
    let tone: [Double]
    let saturation: Double
    let hueGain: [Double]
    let hueShift: [Double]
    let split: [Double]
    let protection: Double
    public var palette: [String] {
        if isMonochrome { return ["#202322", "#797e79", "#dfdfd7"] }
        return split[2] < 0 && split[3] > 0.04 ? ["#47585d", "#a89b58", "#dfc879"] :
            split[0] < -0.03 ? ["#34594d", "#728b79", "#a8b9bf"] : ["#75958e", "#c6b39a", "#e1cbac"]
    }
    public static func profile(id: String) -> PhotoCameraProfile? { all.first { $0.id == id } }
    public static let all: [PhotoCameraProfile] = [
        .init(id: "gr3-negative", title: "GR III・負片", subtitle: "柔和反差、略浮黑位、褪色印相與暖亮部", isMonochrome: false, tone: [0.9, 0.6, 0.05, 0.97], saturation: 0.84, hueGain: [0.04, -0.02, -0.12, -0.04], hueShift: [3, -5, 8, -4], split: [-0.009, -0.009, 0.014, 0.018], protection: 0.55),
        .init(id: "gr3-hardmono", title: "GR III・高反差黑白", subtitle: "深黑與亮白、強化明暗幾何；強度 50 仍維持黑白", isMonochrome: true, tone: [1.95, 0.6, 0.0, 1.0], saturation: 0, hueGain: [0, 0, 0, 0], hueShift: [0, 0, 0, 0], split: [0, 0, 0, 0], protection: 0),
        .init(id: "gr4-yellow", title: "GR IV・Cinema Yellow", subtitle: "黃色亮部、冷陰影、收斂彩度的電影反差", isMonochrome: false, tone: [1.5, 0.6, 0.012, 0.985], saturation: 0.76, hueGain: [0.08, -0.03, -0.18, -0.2], hueShift: [-2, -10, -12, -12], split: [-0.018, -0.012, -0.007, 0.065], protection: 0.7),
        .init(id: "gr4-green", title: "GR IV・Cinema Green", subtitle: "偏綠陰影、偏冷亮部與低彩度都市色調", isMonochrome: false, tone: [1.32, 0.62, 0.015, 0.985], saturation: 0.72, hueGain: [0.05, -0.08, -0.06, -0.05], hueShift: [2, 2, -12, -18], split: [-0.047, 0.02, -0.004, -0.01], protection: 0.84),
    ]
}

/// 與離線樣張共用 Oklab 核心；完整效果由上層統一混合強度，避免重複衰減。
public enum PhotoCameraProcessor {
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    public static func apply(to image: CIImage, profile p: PhotoCameraProfile) -> CIImage {
        guard let kernel, let input = image.matchedFromWorkingSpace(to: linear) else { return image }
        func vector(_ a: [Double]) -> CIVector { a.map { CGFloat($0) }.withUnsafeBufferPointer { CIVector(values: $0.baseAddress!, count: a.count) } }
        guard let output = kernel.apply(extent: image.extent, roiCallback: { _, rect in rect }, arguments: [
            input, vector(p.tone), vector(p.hueGain), vector(p.hueShift.map { $0 * .pi / 180 }),
            vector(p.split), CIVector(x: 1, y: p.saturation, z: p.isMonochrome ? 1 : 0, w: p.protection)
        ]), let matched = output.matchedToWorkingSpace(from: linear) else { return image }
        return matched.cropped(to: image.extent)
    }
    private static let kernel: CIKernel? = try? CIKernel.kernels(withMetalString: source).first { $0.name == "grLook" }
    private static let source = """
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
using namespace coreimage;

// Oklab 轉換取自 Björn Ottosson 公開實作（public domain / MIT）。
// https://bottosson.github.io/posts/oklab/
float3 grToLab(float3 c) {
    float3 lms = float3(dot(c,float3(.4122214708,.5363325363,.0514459929)),
                        dot(c,float3(.2119034982,.6806995451,.1073969566)),
                        dot(c,float3(.0883024619,.2817188376,.6299787005)));
    lms = pow(max(lms,0.0f),float3(1.0f/3.0f));
    return float3(dot(lms,float3(.2104542553,.7936177850,-.0040720468)),
                  dot(lms,float3(1.9779984951,-2.4285922050,.4505937099)),
                  dot(lms,float3(.0259040371,.7827717662,-.8086757660)));
}
float3 grToRGB(float3 c) {
    float3 lms = float3(c.x + .3963377774*c.y + .2158037573*c.z,
                       c.x - .1055613458*c.y - .0638541728*c.z,
                       c.x - .0894841775*c.y - 1.2914855480*c.z);
    lms = lms*lms*lms;
    return float3(dot(lms,float3(4.0767416621,-3.3077115913,.2309699292)),
                  dot(lms,float3(-1.2684380046,2.6097574011,-.3413193965)),
                  dot(lms,float3(-.0041960863,-.7034186147,1.7076147010)));
}
bool grInGamut(float3 c) { return all(c>=0.0f) && all(c<=1.0f); }

// 固定明度與色相，只縮彩度；避免逐通道硬裁切造成亮部變色。
float3 grGamut(float3 lab) {
    float3 rgb=grToRGB(lab);
    if (grInGamut(rgb)) return rgb;
    float low=0.0f, high=1.0f;
    for (int i=0;i<14;++i) {
        float mid=(low+high)*0.5f;
        if (grInGamut(grToRGB(float3(lab.x,lab.yz*mid)))) low=mid; else high=mid;
    }
    return clamp(grToRGB(float3(lab.x,lab.yz*low)),0.0f,1.0f);
}
float grCurve(float L, float4 tone) {
    L=clamp(L,0.0f,1.0f);
    float upper=pow(L,tone.x), lower=pow(1.0f-L,tone.x);
    float pivot=pow(tone.y/(1.0f-tone.y),tone.x-1.0f);
    return mix(tone.z,tone.w,upper/max(upper+lower*pivot,1e-12f));
}
[[ stitchable ]] float4 grLook(coreimage::sampler input, float4 tone, float4 hueGain, float4 hueShift,
                               float4 split, float4 controls, destination dest) {
    float4 pixel=input.sample(input.transform(dest.coord()));
    float alpha=isfinite(pixel.a) ? clamp(pixel.a,0.0f,1.0f) : 0.0f;
    if (alpha<=0.0f) return float4(0.0f);
    float3 rgb=pixel.rgb/alpha;
    rgb=clamp(select(float3(0.0f),rgb,isfinite(rgb)),0.0f,1.0f);
    float3 lab=grToLab(rgb);
    float sourceL=lab.x;
    float L=grCurve(sourceL,tone);
    float3 base=rgb, result;
    if (controls.z>0.5f) {
        // 中性灰階用線性亮度；強度只調反差，避免 50% 變成半彩色。
        float luminance=dot(rgb,float3(.2126,.7152,.0722));
        base=float3(luminance);
        float monoL=grCurve(pow(luminance,1.0f/3.0f),tone);
        result=float3(monoL*monoL*monoL);
    } else {
        float chroma=length(lab.yz), hue=atan2(lab.z,lab.y);
        float hueReliability=smoothstep(.015f,.065f,chroma);
        float4 centres=float4(40.0f,100.0f,145.0f,255.0f)*M_PI_F/180.0f;
        // 週期連續的色相權重，無區間接縫；近中性像素不旋轉色相。
        float4 weights=exp(9.0f*(cos(hue-centres)-1.0f))*hueReliability;
        float warm=exp(8.0f*(cos(hue-48.0f*M_PI_F/180.0f)-1.0f))*smoothstep(.005f,.030f,chroma);
        warm*=smoothstep(.10f,.35f,sourceL)*(1.0f-smoothstep(.92f,1.0f,sourceL));
        float protection=1.0f-controls.w*warm;
        float saturation=1.0f+(controls.y-1.0f+dot(weights,hueGain))*protection;
        float angle=dot(weights,hueShift)*protection;
        float cs=cos(angle), sn=sin(angle);
        float2 ab=float2(cs*lab.y-sn*lab.z,sn*lab.y+cs*lab.z)*max(saturation,0.0f);
        float shadow=1.0f-smoothstep(.20f,.70f,sourceL);
        float highlight=smoothstep(.40f,.90f,sourceL);
        float taper=smoothstep(0.0f,.12f,L)*(1.0f-smoothstep(.88f,1.0f,L));
        ab+=(split.xy*shadow+split.zw*highlight)*taper*protection;
        result=grGamut(float3(L,ab));
    }
    return float4(mix(base,result,controls.x)*alpha,alpha);
}

"""
}
