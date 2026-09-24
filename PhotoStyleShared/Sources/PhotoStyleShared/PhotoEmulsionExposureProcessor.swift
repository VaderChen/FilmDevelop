import CoreImage
import Foundation

/// Independent RGB emulsion study inspired by polygon-crystal capture and
/// layered Poisson transport. This is not spectral photon tracing or measured
/// chemistry. Fixed cell seeds define one particle realization for the frame.
/// Captured + transmitted = incident per pixel before display normalization.
public enum PhotoEmulsionExposureProcessor {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static var kernelsAreAvailable: Bool { field != nil && transmission != nil && composite != nil && returned != nil }
    public static func apply(to image: CIImage, effects: PhotoFilmEffects,
                             amounts: PhotoToneZoneGrainAmounts, strength: Double = 1,
                             monochrome: Bool = false, seed: UInt32 = 0) -> CIImage {
        let e = effects.clamped()
        guard e.grainMode == .emulsion,
              max(amounts.shadows, max(amounts.midtones, amounts.highlights)) > 0 || e.halationAmount * strength > 0,
              let field, let transmission, let composite, let returned,
              let linear = image.matchedFromWorkingSpace(to: space) else { return image }
        let extent = image.extent, longEdge = max(extent.width, extent.height)
        guard longEdge.isFinite, longEdge > 0, extent.width > 0, extent.height > 0 else { return image }
        // One 3000px integration grid for both preview and export. Physical
        // particle coordinates remain referenced to a 3000px full-frame edge.
        // Four area samples/pixel integrate footprints; export cannot invent
        // additional particles. Very fine grains retain this declared bandwidth.
        let scale = longEdge / 3000
        let source = linear.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: .init(scaleX: 1 / scale, y: 1 / scale))
        let canonical = CGRect(x: 0, y: 0, width: extent.width / scale, height: extent.height / scale)
        let radius = 12 * e.grainSize
        guard let captureGraph = field.apply(extent: canonical, roiCallback: { _, r in r.insetBy(dx: -radius, dy: -radius) },
            arguments: [source.clampedToExtent(), e.grainSize, e.grainClumping / 100,
                        monochrome ? 0 : e.grainChroma / 100, Double(seed & 0xffff), Double(seed >> 16)]) else { return image }
        // 紅暈與成品共用同一個捕獲場，避免分支重算晶體取樣。
        let captured = captureGraph.insertingIntermediate(cache: true)
        let halo = min(1, max(0, strength.isFinite ? strength : 0)) * PhotoFilmEffects.effectAmount(e.halationAmount)
        let bounced: CIImage
        if halo > 0 {
            guard let remaining = transmission.apply(extent: canonical, arguments: [source, captured]),
                  let reflected = returned.apply(extent: canonical, arguments: [source, remaining, halo, PhotoFilmEffects.linearLightThreshold(e.halationThreshold)]) else { return image }
            let sigma = 3000 * e.halationRadius / 100
            bounced = reflected.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma]).cropped(to: canonical)
        } else {
            // 關閉紅暈時不建立透射、反射與模糊分支；顆粒捕獲仍照常計算。
            bounced = CIImage(color: .clear).cropped(to: canonical)
        }
        func full(_ input: CIImage) -> CIImage {
            let scaled = scale < 1 ? input.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters:
                [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1]) : input.clampedToExtent().transformed(by: .init(scaleX: scale, y: scale))
            return scaled.transformed(by: .init(translationX: extent.minX, y: extent.minY)).cropped(to: extent)
        }
        let masks = PhotoToneMasks(input: image, profile: .layered)
        guard let result = composite.apply(extent: extent, arguments: [linear, full(captured), full(bounced),
            masks.shadows, masks.midtones, masks.highlights,
            CIVector(x: unit(amounts.shadows), y: unit(amounts.midtones), z: unit(amounts.highlights)),
            monochrome ? 0 : e.grainChroma / 100, e.grainClumping / 100]) else { return image }
        return result.matchedToWorkingSpace(from: space) ?? image
    }
    private static func unit(_ x: Double) -> Double { x.isFinite ? min(1,max(0,x)) : 0 }
    // Exposed internally to test the raw photon budget independently from gain.
    static func capturedField(_ image: CIImage, size: Double = 1, seed: UInt32 = 0) -> CIImage? {
        field?.apply(extent: image.extent, roiCallback: { _, r in r.insetBy(dx: -24, dy: -24) },
            arguments: [image.clampedToExtent(), size, 0.0, 1.0, Double(seed & 0xffff), Double(seed >> 16)])
    }
    private static let kernels: [CIKernel] = {
        let source = """
        #include <metal_stdlib>
        #include <CoreImage/CoreImage.h>
        using namespace metal; using namespace coreimage;
        uint eh(uint x) { x^=x>>16; x*=0x7feb352du; x^=x>>15; x*=0x846ca68bu; return x^(x>>16); }
        float eu(uint x) { return (float(eh(x)>>8)+0.5f)/16777216.0f; }
        uint cellSeed(int2 p, uint seed) { return eh(uint(p.x)*0x9e3779b9u ^ uint(p.y)*0x85ebca6bu ^ seed); }
        // Inverse Poisson CDF. lambda <= 1.5; P(K>=20) < 4e-16.
        // Counts depend on the cell, never the querying pixel or its exposure.
        int countPoisson(uint seed, float lambda) {
            float p=exp(-lambda), sum=p, u=eu(seed); int k=0;
            for (int i=1; i<20 && u>sum; ++i) { p*=lambda/float(i); sum+=p; k=i; }
            return k;
        }
        float3 radiance(coreimage::sampler src, float2 p) {
            float4 c=src.sample(src.transform(p));
            return c.a>0.0 ? max(float3(0.0),c.rgb/c.a) : float3(0.0);
        }
        [[ stitchable ]] float4 emulsionCapture(coreimage::sampler src, float size, float clumping,
            float chroma, float seedLo, float seedHi, destination dest) {
            float2 p=dest.coord(); float4 original=src.sample(src.transform(p));
            if (!(original.a>0.0)) return float4(0.0);
            float3 incident=max(original.rgb/original.a,float3(0.0));
            if (!all(isfinite(incident))) return float4(0.0,0.0,0.0,original.a);
            uint seed=uint(seedLo)|(uint(seedHi)<<16);
            float spacing=3.6f*size;
            float3 total=float3(0.0); float opacity=0.0f;
            for(int sample=0;sample<4;++sample) {
                float2 q=p+float2((sample&1)?0.25f:-0.25f,(sample&2)?0.25f:-0.25f);
                float3 remaining=incident; float throughput=1.0f;
                for(int layer=0;layer<3;++layer) {
                    uint layerSeed=seed ^ (0x243f6a88u+uint(layer)*0x9e3779b9u);
                    int2 cell=int2(floor(q/spacing));
                    float hits=0.0; float3 footprint=float3(0.0);
                    for(int cy=-1;cy<=1;++cy) for(int cx=-1;cx<=1;++cx) {
                        int2 candidate=cell+int2(cx,cy); uint key=cellSeed(candidate,layerSeed);
                        float group=eu(cellSeed(int2(floor(float2(candidate)/5.0f)),layerSeed));
                        float lambda=mix(1.2f,0.9f+0.6f*group,clumping);
                        int count=countPoisson(key,lambda);
                        for(int j=0;j<count;++j) {
                            uint h=eh(key ^ uint(j+1)*0x63d83595u);
                            float2 center=(float2(candidate)+float2(eu(h),eu(h^0xa511e9b3u)))*spacing;
                            float radius=(0.25f+0.10f*eu(h^0x3c6ef372u))*spacing;
                            float angle=6.2831853f*eu(h^0xbb67ae85u); float cs=cos(angle),sn=sin(angle);
                            float2 d=q-center; d=float2(cs*d.x+sn*d.y,-sn*d.x+cs*d.y);
                            float edge=max(abs(d.x),max(abs(0.5f*d.x+0.8660254f*d.y),abs(-0.5f*d.x+0.8660254f*d.y)));
                            if(edge<=0.8660254f*radius) {
                                // One crystal sees a common footprint exposure;
                                // finite capture capacity occludes sub-grain detail.
                                footprint+=(radiance(src,center)+radiance(src,center+float2(radius*0.5f,0))+
                                    radiance(src,center-float2(radius*0.5f,0)))/3.0f;
                                hits+=1.0f;
                            }
                        }
                    }
                    float3 tau=mix(float3(0.70f),layer==0?float3(0.25f,0.5f,1.35f):
                        (layer==1?float3(0.5f,1.35f,0.25f):float3(1.35f,0.25f,0.5f)),chroma);
                    throughput*=exp(-0.70f*hits);
                    float3 capacity=hits>0.0 ? footprint/hits : float3(0.0);
                    float3 absorbed=min(remaining,capacity)*(1.0f-exp(-tau*hits));
                    remaining-=absorbed;
                }
                total+=incident-remaining; opacity+=1.0f-throughput;
            }
            // Alpha carries the scalar reverse-pass opacity (a data channel),
            // including unexposed grains. Final output restores source alpha.
            return float4(total*(0.25f*original.a),opacity*(0.25f*original.a));
        }
        [[ stitchable ]] float4 emulsionTransmission(sample_t source,sample_t captured) {
            return float4(max(source.rgb-captured.rgb,float3(0.0)),source.a);
        }
        [[ stitchable ]] float4 emulsionReturn(sample_t source,sample_t transmitted,float amount,float threshold) {
            float y=source.a>0.0?dot(max(source.rgb/source.a,float3(0.0)),float3(0.2126,0.7152,0.0722)):0.0;
            float gate=smoothstep(threshold,threshold+0.25f,y);
            // Channel-wise substrate reflectance. The unreturned remainder escapes.
            return float4(transmitted.rgb*float3(0.65f,0.16f,0.035f)*(amount*gate),source.a);
        }
        [[ stitchable ]] float4 emulsionComposite(sample_t source,sample_t captured,sample_t bounced,
            sample_t shadows,sample_t midtones,sample_t highlights,float3 amounts,float chroma,float clumping) {
            float3 weights=max(float3(shadows.r,midtones.r,highlights.r),float3(0.0));
            float amount=dot(weights,amounts)/max(dot(weights,float3(1.0)),0.000001f);
            // Flat-field expected absorption: three Poisson polygon layers.
            // Hex area = 3sqrt(3)/2 r², E[r²]=(.25²+.25*.35+.35²)/3.
            float mu=1.2f*2.598076211f*(0.25f*0.25f+0.25f*0.35f+0.35f*0.35f)/3.0f;
            float3 tau=mix(float3(0.70f),float3(0.25f,0.5f,1.35f),chroma);
            float3 exponent=mu*(exp(-tau)-1.0f);
            // Each layer has an independent uniform density modulation. Its
            // Poisson Laplace transform fixes mean drift from chroma/clumping.
            float3 delta=exponent*0.25f*clumping;
            float3 correction=float3(1.0f)+delta*delta/6.0f+delta*delta*delta*delta/120.0f;
            float absorption=1.0f-exp(exponent.x+exponent.y+exponent.z)*correction.x*correction.y*correction.z;
            float fraction=source.a>0.0f ? clamp(captured.a/source.a,0.0f,1.0f) : 0.0f;
            float peak=source.a>0.0f ? max(source.r,max(source.g,source.b))/source.a : 0.0f;
            // Finite developed-grain contrast saturates in HDR; radiance itself
            // is preserved and never clipped to the display interval.
            float grainMix=amount*0.35f/max(1.0f,peak);
            float3 developed=mix(source.rgb,captured.rgb/absorption,grainMix);
            // Returning light traverses the same absorption field a second time.
            developed+=bounced.rgb*fraction/absorption;
            return float4(developed,source.a);
        }
        """
        do { return try CIKernel.kernels(withMetalString: source) }
        catch { NSLog("Emulsion kernel: %@", String(describing: error)); return [] }
    }()
    private static let field = kernels.first { $0.name == "emulsionCapture" }
    private static let transmission = kernels.first { $0.name == "emulsionTransmission" } as? CIColorKernel
    private static let returned = kernels.first { $0.name == "emulsionReturn" } as? CIColorKernel
    private static let composite = kernels.first { $0.name == "emulsionComposite" } as? CIColorKernel
}
