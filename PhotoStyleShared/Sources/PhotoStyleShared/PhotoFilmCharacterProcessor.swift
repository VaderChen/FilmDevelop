import CoreImage

/// Output rendering recipes applied only to film looks, before the user's intensity mix.
/// Point operations remain on the GPU; no readback or full-frame analysis is needed.
public enum PhotoFilmCharacterProcessor {
    static func recipe(_ stock: PhotoFilmStock) -> (SIMD2<Double>, SIMD4<Double>)? {
        // Tone: luminance contrast, midtone warmth.
        // Palette: warm/cool hue saturation, shadow/highlight warmth.
        switch stock {
        case .filmPortra160: return (.init(0.96, 0.06), .init(0.90, 0.76, 0, 0.02))
        case .filmPortra400: return (.init(1, 0.07), .init(1.00, 0.88, -0.01, 0.03))
        case .filmPortra800: return (.init(1.06, 0.09), .init(1.10, 0.94, -0.025, 0.04))
        case .filmEktar100: return (.init(1.04, 0), .init(1.04, 1.14, 0, 0))
        case .filmVision50D: return (.init(1, 0), .init(1.02, 1.06, -0.015, 0.025))
        case .filmVision250D: return (.init(0.96, 0), .init(0.94, 0.98, -0.045, 0.035))
        case .filmVision200T: return (.init(1.02, 0), .init(1.04, 1.08, -0.055, 0.04))
        case .filmVision500T: return (.init(0.94, 0), .init(1.02, 0.96, -0.10, 0.065))
        case .filmEktachrome100: return (.init(0.96, 0), .init(1.05, 1.05, 0, 0))
        case .filmVelvia50: return (.init(1.12, 0), .init(1.18, 1.32, 0, 0))
        case .filmProvia100F: return (.init(1.02, 0), .init(1, 1.02, 0, 0))
        case .filmHP5: return (.init(1.06, 0), .init(1, 1, 0, 0))
        case .filmFP4: return (.init(0.98, 0), .init(1, 1, 0, 0))
        case .filmOrtho80: return (.init(1.10, 0), .init(1, 1, 0, 0))
        case .filmSFX200: return (.init(1.08, 0), .init(1, 1, 0, 0))
        case .filmInfrared400: return (.init(1.16, 0), .init(1, 1, 0, 0))
        case .filmDelta3200: return (.init(0.92, 0), .init(1, 1, 0, 0))
        case .filmBleachBypass: return (.init(1.08, 0), .init(0.80, 0.80, 0, 0))
        case .filmLomoPurple: return (.init(1.04, 0), .init(1.08, 1.16, 0, 0))
        case .filmCrossProcess, .filmGold200, .filmCineStill800T, .filmPolaroidSX70: return nil
        }
    }

    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let kernel = PhotoGPUColorKernel.make("filmCharacter",
        parameters: "__sample source, vec2 tone, vec4 palette, float mono", body: """
        float alpha=source.a;
        if(alpha<=0.0) return vec4(0.0);
        vec3 rgb=max(source.rgb/alpha,vec3(0.0));
        vec3 w=vec3(0.2126,0.7152,0.0722);
        float before=dot(rgb,w), y=before;
        if(y>0.0 && y<1.0 && tone.x!=1.0) {
            float z=tone.x*(log(y/(1.0-y))-log(0.18/0.82))+log(0.18/0.82);
            y=1.0/(1.0+exp(-clamp(z,-80.0,80.0)));
        }
        rgb=before>1e-12 ? rgb*(y/before) : vec3(y);
        if(mono>0.5) return vec4(vec3(y)*alpha,alpha);
        // Smooth hue weighting: no hard color regions and no per-channel clipping.
        float warm=smoothstep(-0.25,0.25,(rgb.r-rgb.b)/max(0.02,y));
        rgb=vec3(y)+(rgb-y)*mix(palette.y,palette.x,warm);
        float shadows=smoothstep(0.0,0.012,y)*(1.0-smoothstep(0.025,0.18,y));
        float highlights=smoothstep(0.25,0.70,y)*(1.0-smoothstep(0.85,1.0,y));
        float mid=smoothstep(0.025,0.18,y)*(1.0-smoothstep(0.3,0.65,y));
        // Fit saturation first so the subsequent temperature operation has valid RGB.
        vec3 d=rgb-y;
        float scale=1.0, ceiling=max(1.0,y);
        for(int c=0;c<3;++c) {
            if(d[c]<0.0) scale=min(scale,y/-d[c]);
            if(d[c]>0.0) scale=min(scale,(ceiling-y)/d[c]);
        }
        rgb=vec3(y)+d*max(0.0,scale);
        float warmth=palette.z*shadows+palette.w*highlights+tone.y*mid;
        rgb*=exp2(vec3(0.35,0.10,-0.4)*warmth);
        rgb*=y/max(1e-12,dot(rgb,w));
        d=rgb-y; scale=1.0;
        for(int c=0;c<3;++c) {
            if(d[c]<0.0) scale=min(scale,y/-d[c]);
            if(d[c]>0.0) scale=min(scale,(ceiling-y)/d[c]);
        }
        return vec4((vec3(y)+d*max(0.0,scale))*alpha,alpha);
        """)

    public static func apply(to image: CIImage, stock: PhotoFilmStock) -> CIImage {
        guard let (tone, palette) = recipe(stock), let kernel,
              let linear = image.matchedFromWorkingSpace(to: space),
              let result = kernel.apply(extent: image.extent, arguments: [
                linear, CIVector(x:tone.x,y:tone.y),
                CIVector(x:palette.x,y:palette.y,z:palette.z,w:palette.w),
                stock.isMonochrome ? 1.0 : 0.0
              ]) else { return image }
        return result.matchedToWorkingSpace(from: space) ?? image
    }
}
