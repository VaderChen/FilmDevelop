import CoreImage

/// D65 Lab color edits in one pointwise GPU pass; neutral settings bypass it.
public enum PhotoLabAdjustmentProcessor {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let helpers = PhotoExposureColor.kernel + """
    vec3 labColorRGB(float fy, vec2 ab) {
        vec3 xyz=vec3(0.9504559270516716*exposureLabInverse(fy+ab.x/500.0),
            exposureLabInverse(fy),1.0890577507598784*exposureLabInverse(fy-ab.y/200.0));
        return vec3(dot(xyz,vec3(3.240969941904521,-1.537383177570093,-0.498610760293)),
            dot(xyz,vec3(-0.9692436362808796,1.8759675015077202,0.04155505740717559)),
            dot(xyz,vec3(0.05563007969699366,-0.20397695888897652,1.0569715142428786)));
    }
    """
    static let colorKernel = PhotoGPUColorKernel.make("labColorAdjustment",
        parameters: "__sample source, float vibrance, float saturation", body: """
        if(source.a<=0.0) return vec4(0.0);
        vec3 rgb=source.rgb/source.a;
        float y=dot(rgb,vec3(0.21263900587151027,0.7151686787677559,0.07219231536073371));
        if(y<=0.0) return source;
        float fy=exposureLabF(y);
        float x=dot(rgb,vec3(0.41239079926595934,0.35758433938387796,0.1804807884018343));
        float z=dot(rgb,vec3(0.01933081871559185,0.11919477979462599,0.9505321522496607));
        vec2 ab=vec2(500.0*(exposureLabF(x/0.9504559270516716)-fy),
            200.0*(fy-exposureLabF(z/1.0890577507598784)));
        float muted=1.0-smoothstep(0.0,100.0,length(ab));
        ab*=max(0.0,1.0+saturation)*max(0.0,1.0+vibrance*muted);
        vec3 result=labColorRGB(fy,ab);
        // Fit only out-of-gamut colors along the Lab hue, retaining L and HDR headroom.
        float lower=min(0.0,min(rgb.r,min(rgb.g,rgb.b)));
        float upper=max(1.0,max(rgb.r,max(rgb.g,rgb.b)));
        if(min(result.r,min(result.g,result.b))<lower || max(result.r,max(result.g,result.b))>upper) {
            float lo=0.0,hi=1.0;
            for(int i=0;i<12;++i) {
                float mid=(lo+hi)*0.5;
                vec3 candidate=labColorRGB(fy,ab*mid);
                if(min(candidate.r,min(candidate.g,candidate.b))>=lower && max(candidate.r,max(candidate.g,candidate.b))<=upper) lo=mid;
                else hi=mid;
            }
            result=labColorRGB(fy,ab*lo);
        }
        return vec4(result*source.a,source.a);
        """, helpers: helpers)

    private static let lightnessKernel = PhotoGPUColorKernel.make("labRestoreChroma",
        parameters: "__sample source, __sample adjusted", body: """
        if(source.a<=0.0) return vec4(0.0);
        vec3 rgb=source.rgb/source.a;
        vec3 target=adjusted.rgb/max(adjusted.a,1.0e-20);
        vec3 weights=vec3(0.21263900587151027,0.7151686787677559,0.07219231536073371);
        float y=dot(rgb,weights), targetY=max(0.0,dot(target,weights));
        if(y<=1.0e-20) return vec4(vec3(targetY)*source.a,source.a);
        return vec4(exposureLabLuminance(rgb,y,targetY/y,0.0)*source.a,source.a);
        """, helpers: PhotoExposureColor.kernel)

    public static func apply(to image: CIImage, vibrance: Double, saturation: Double) -> CIImage {
        let v = vibrance.isFinite ? min(100,max(-100,vibrance))/100 : 0
        let s = saturation.isFinite ? min(100,max(-100,saturation))/100 : 0
        guard v != 0 || s != 0, let colorKernel,
              let linear = image.matchedFromWorkingSpace(to: space),
              let output = colorKernel.apply(extent: image.extent, arguments: [linear,v,s]) else { return image }
        return output.matchedToWorkingSpace(from: space) ?? image
    }

    /// Keep an existing tone model's resulting luminance, reconstruct with source Lab a/b.
    /// Spatial detail, masks and tone curves are unchanged; no CPU readback is added.
    public static func replacingLightness(of source: CIImage, with adjusted: CIImage) -> CIImage {
        guard source !== adjusted, let lightnessKernel,
              let linear = source.matchedFromWorkingSpace(to: space),
              let target = adjusted.matchedFromWorkingSpace(to: space),
              let output = lightnessKernel.apply(extent: source.extent, arguments: [linear,target]) else { return source }
        return output.matchedToWorkingSpace(from: space) ?? source
    }
}
