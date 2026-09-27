import CoreImage

/// Relative density response before the stock/print curves. Neutral is an exact bypass.
/// Lab preserves chroma for tone changes; intentional layer crossover stays in linear RGB.
public enum PhotoDeveloperChemistryProcessor {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let densityHelpers = """
    float developerLogExposure(float y, vec3 curve) {
        float x=log(max(y,1.0e-10)/0.18)/log(10.0)+curve.y*0.3010299956639812;
        float z=max(x-0.3010299956639812,0.0);
        if(curve.z>0.0 && z>0.0) {
            float u=curve.z*z;
            // log(1+u)/u loses all low bits near zero in FP32. Its series
            // preserves the same curve, including continuity at neutral.
            float ratio=u<0.001 ? 1.0-u*0.5+u*u*(0.333333333333-u*0.25) : log(1.0+u)/u;
            x+=z*(ratio-1.0);
        }
        return x;
    }
    float developerDensity(float x,float contrast) {
        return 0.08+2.4/(1.0+exp(clamp(-4.0*0.65*contrast*x/2.4,-60.0,60.0)));
    }
    float developerInverse(float d) {
        float p=clamp((d-0.08)/2.4,0.00001,0.99999);
        float x=log(p/(1.0-p))/(4.0*0.65/2.4);
        return 0.18*exp(clamp(x*log(10.0),-60.0,25.0));
    }
    """
    private static let densityKernel = PhotoGPUColorKernel.make("developerDensityField",
        parameters: "__sample source, vec3 curve", body: """
        if(source.a<=0.0) return vec4(0.0);
        float y=dot(source.rgb/source.a,vec3(0.2126390059,0.7151686788,0.0721923154));
        float d=developerDensity(developerLogExposure(y,curve),curve.x);
        return vec4(vec3(d)*source.a,source.a);
        """, helpers: densityHelpers)

    static let responseKernel = PhotoGPUColorKernel.make("developerChemistryResponse",
        parameters: "__sample source, __sample meanDensity, vec3 curve, vec3 layers, vec3 detail, vec3 coordinates, float amount",
        body: """
        if(source.a<=0.0) return vec4(0.0);
        vec3 rgb=source.rgb/source.a;
        vec3 weights=vec3(0.2126390059,0.7151686788,0.0721923154);
        float y=dot(rgb,weights);
        if(y<=1.0e-10) return source;
        float x=developerLogExposure(y,curve);
        float d=developerDensity(x,curve.x);
        if(detail.y>0.0) {
            float local=meanDensity.r/max(meanDensity.a,1.0e-10);
            float delta=d-local;
            d+=detail.y*delta/(1.0+abs(delta)/0.08);
        }
        if(detail.x>0.0) {
            vec2 p=(destCoord()-coordinates.xy)*coordinates.z;
            vec2 cell=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
            float n=mix(mix(developerNoise(cell),developerNoise(cell+vec2(1.0,0.0)),f.x),
                        mix(developerNoise(cell+vec2(0.0,1.0)),developerNoise(cell+vec2(1.0,1.0)),f.x),f.y);
            d+=detail.x*n;
        }
        float target=developerInverse(d);
        // Limit extreme relative gains, retaining HDR rather than clipping RGB to white.
        target=y*clamp(target/y,0.015625,64.0);
        vec3 result=exposureLabLuminance(rgb,y,target/y,0.0);
        if(detail.z<0.5 && dot(abs(layers),vec3(1.0))>0.0) {
            result*=exp(clamp(x,-3.0,2.0)*layers*log(10.0));
            float colorY=dot(result,weights);
            // Wide-gamut RAW can contain negative channels. Color-layer gains
            // may make their weighted sum nonpositive: never divide by epsilon
            // and then try to cancel the resulting enormous chroma components.
            if(colorY<=target*0.0001) {
                result+=vec3(target-colorY);
                colorY=target;
            }
            result*=target/colorY;
            float lower=min(0.0,min(rgb.r,min(rgb.g,rgb.b)))*target/y;
            float minimum=min(result.r,min(result.g,result.b));
            if(minimum<lower) result=vec3(target)+(result-vec3(target))*clamp((target-lower)/(target-minimum),0.0,1.0);
        }
        return vec4(mix(rgb,result,amount)*source.a,source.a);
        """, destination: true, helpers: PhotoExposureColor.kernel + densityHelpers + """
        float developerNoise(vec2 p) {
            return 2.0*fract(sin(dot(p,vec2(127.1,311.7))+17.0)*43758.5453)-1.0;
        }
        """)

    public static func apply(to image: CIImage, settings: PhotoDeveloperSettings,
                             strength: Double = 1, monochrome: Bool = false) -> CIImage {
        var s = settings.clamped()
        if monochrome { s.red = 0; s.green = 0; s.blue = 0 }
        let amount = strength.isFinite ? min(1, max(0, strength)) : 0
        let extent = image.extent
        guard amount > 0, s != .neutral, !extent.isEmpty, !extent.isInfinite,
              extent.minX.isFinite, extent.minY.isFinite,
              let responseKernel, let linear = image.matchedFromWorkingSpace(to: space) else { return image }
        let curve = CIVector(x: s.contrast, y: s.speedEV, z: s.compensation / 50)
        let mean: CIImage
        if s.acutance > 0 {
            guard let densityKernel,
                  let field = densityKernel.apply(extent: extent, arguments: [linear, curve]) else { return image }
            let radius = max(0.5, 2 * max(extent.width, extent.height) / 3000)
            mean = field.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        } else { mean = linear }
        guard let output = responseKernel.apply(extent: extent, arguments: [linear, mean, curve,
            CIVector(x: s.red / 100, y: s.green / 100, z: s.blue / 100),
            CIVector(x: s.grain / 100 * 0.018, y: s.acutance / 100 * 0.24, z: monochrome ? 1 : 0),
            CIVector(x: extent.minX, y: extent.minY, z: 3000 / max(extent.width, extent.height)), amount]) else { return image }
        return (output.matchedToWorkingSpace(from: space) ?? image).cropped(to: extent)
    }
}
