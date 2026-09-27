import CoreImage
import Foundation

/// LYT-Net predicts luminance; edge-aware source chromaticity reconstruction
/// restores color as shadows brighten. The network never invents image colors.
public enum PhotoDeepShadowExposureProcessor {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let context = CIContext(options: [.workingColorSpace: space,
        .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    private static let guideKernel = PhotoGPUColorKernel.make("deepShadowLuminanceInput",
        parameters: "__sample source", body: """
        vec3 rgb = source.rgb/max(source.a,1.0e-20);
        float y = clamp(dot(rgb,vec3(0.21263900587151027,0.7151686787677559,0.07219231536073371)),0.0,1.0);
        float encoded = y <= 0.0031308 ? y*12.92 : 1.055*pow(y,1.0/2.4)-0.055;
        return vec4(encoded,encoded,encoded,1.0);
        """)
    private static let detailKernel = PhotoGPUColorKernel.make("deepShadowDetailGuide",
        parameters: "__sample source", body: """
        vec3 rgb = source.rgb/max(source.a,1.0e-20);
        float y = dot(rgb,vec3(0.21263900587151027,0.7151686787677559,0.07219231536073371));
        float guide = log2(max(y,1.0e-8));
        return vec4(guide,guide,guide,1.0);
        """)
    // Small joint bilateral neighborhood: luminance edges gate color averaging.
    // It reduces amplified shadow color noise without a full-frame CPU buffer.
    private static let colorGuideKernel: CIKernel? = {
        let body = """
        vec2 p = destCoord();
        vec4 center = sample(source, samplerTransform(source,p));
        vec3 weights = vec3(0.21263900587151027,0.7151686787677559,0.07219231536073371);
        vec3 rgb = center.rgb/max(center.a,1.0e-20);
        float y = dot(rgb,weights);
        float logY = log2(max(y,1.0e-8));
        vec3 sum = vec3(0.0), squared = vec3(0.0); float total = 0.0;
        for (int row=-2; row<=2; ++row) {
            for (int col=-2; col<=2; ++col) {
                vec2 d = vec2(float(col),float(row));
                vec2 q = p+d*radius;
                vec4 neighbor = sample(source, samplerTransform(source,q));
                vec3 color = neighbor.rgb/max(neighbor.a,1.0e-20);
                float ny = dot(color,weights);
                float distance = log2(max(ny,1.0e-8))-logY;
                // Reject strong color edges even when their luminance is equal.
                // The floor avoids unstable chromaticity ratios below the noise floor.
                vec3 chromaDelta = color/max(ny,1.0e-5)-rgb/max(y,1.0e-5);
                float edgeConfidence = smoothstep(0.0001,0.003,max(y,ny));
                float w = exp(-0.5*dot(d,d)-edgeConfidence*(2.0*distance*distance
                              +0.125*dot(chromaDelta,chromaDelta)));
                w *= clamp(neighbor.a,0.0,1.0);
                sum += color*w; squared += color*color*w; total += w;
            }
        }
        vec3 mean = total>1.0e-8 ? sum/total : rgb;
        vec3 variance = max(vec3(0.0),squared/max(total,1.0e-8)-mean*mean);
        float signal = max(dot(mean,weights),0.0);
        float confidence = signal*signal/max(signal*signal+4.0*dot(variance,weights),1.0e-20);
        return vec4(mean,clamp(confidence,0.0,1.0));
        """
        if PhotoGPUColorKernel.supportsMetal {
            let metalBody = body.replacingOccurrences(of:"vec2",with:"float2")
                .replacingOccurrences(of:"vec3",with:"float3").replacingOccurrences(of:"vec4",with:"float4")
                .replacingOccurrences(of:"destCoord()",with:"dest.coord()")
                .replacingOccurrences(of:"sample(source, samplerTransform(source,p))",with:"source.sample(source.transform(p))")
                .replacingOccurrences(of:"sample(source, samplerTransform(source,q))",with:"source.sample(source.transform(q))")
            let code = """
            #include <metal_stdlib>
            #include <CoreImage/CoreImage.h>
            using namespace metal;
            using namespace coreimage;
            [[ stitchable ]] float4 deepShadowColorGuide(coreimage::sampler source, float radius, destination dest) { \(metalBody) }
            """
            if let kernel = try? CIKernel.kernels(withMetalString:code).first { return kernel }
        }
        return CIKernel(source:"kernel vec4 deepShadowColorGuide(sampler source, float radius) { \(body) }")
    }()
    private static let adjustmentKernel = PhotoGPUColorKernel.make("deepShadowLuminanceBlend",
        parameters: "__sample source, __sample detail, __sample coefficients, __sample colorGuide, float amount", body: """
        if (source.a <= 0.0) return source;
        vec3 rgb = source.rgb/source.a;
        float y = dot(rgb,vec3(0.21263900587151027,0.7151686787677559,0.07219231536073371));
        if (y <= 1.0e-20 || y >= 0.8) return source;
        float predicted = exp2(clamp(coefficients.r*detail.r+coefficients.g,-26.575425,0.0));
        // Blend the predicted luminance without a low ceiling that would flatten
        // brightened walls. Protect existing highlights with a smooth C2 taper.
        float t = clamp((y-0.25)/0.55,0.0,1.0);
        float weight = 1.0-t*t*t*(t*(t*6.0-15.0)+10.0);
        float enhanced = y+max(0.0,predicted-y)*weight;
        if (enhanced <= y) return source;
        // Lift chroma in Lab while keeping its hue; frozen a/b washes out,
        // whereas multiplying tiny/negative RGB channels creates false colors.
        vec3 weights = vec3(0.21263900587151027,0.7151686787677559,0.07219231536073371);
        float cleanY = dot(colorGuide.rgb,weights);
        float lift = log2(max(enhanced/y,1.0));
        float denoise = smoothstep(0.0,4.0,lift)*(1.0-smoothstep(0.005,0.04,y));
        vec3 color = rgb;
        if (cleanY>1.0e-8) color = mix(rgb,colorGuide.rgb*(y/cleanY),denoise);
        float fy = exposureLabF(y);
        float x = dot(color,vec3(0.41239079926595934,0.35758433938387796,0.1804807884018343));
        float z = dot(color,vec3(0.01933081871559185,0.11919477979462599,0.9505321522496607));
        vec2 ab = vec2(500.0*(exposureLabF(x/0.9504559270516716)-fy),
                      200.0*(fy-exposureLabF(z/1.0890577507598784)));
        // Lab uses a linear toe near black and a cube-root branch above it.
        // A bounded sublinear gain bridges these regions without copying the
        // full exposure gain into chroma. The 0.6 toe exponent is tuned locally.
        float exponent = mix(0.6,0.3333333333,smoothstep(0.002,0.02,y));
        float colorGain = exp2(min(20.0,lift)*exponent);
        float confidence = mix(1.0,sqrt(max(colorGuide.a,0.0)),denoise);
        ab *= colorGain*confidence*smoothstep(1.0e-8,1.0e-6,y);
        float chroma = length(ab);
        if (chroma>80.0) ab *= (80.0+20.0*(1.0-exp(-(chroma-80.0)/20.0)))/chroma;
        float targetFY = exposureLabF(enhanced);
        vec3 fullColor = deepShadowLabRGB(targetFY,ab);
        float upper = max(1.0,max(rgb.r,max(rgb.g,rgb.b)));
        // Reduce Lab chroma at fixed L/hue when the reconstructed color is
        // outside the output gamut; never clamp RGB channels independently.
        if (min(fullColor.r,min(fullColor.g,fullColor.b))<0.0 || max(fullColor.r,max(fullColor.g,fullColor.b))>upper) {
            float lo=0.0, hi=1.0;
            for (int i=0;i<12;++i) {
                float mid=(lo+hi)*0.5;
                vec3 candidate=deepShadowLabRGB(targetFY,ab*mid);
                if (min(candidate.r,min(candidate.g,candidate.b))>=0.0 && max(candidate.r,max(candidate.g,candidate.b))<=upper) lo=mid;
                else hi=mid;
            }
            fullColor=deepShadowLabRGB(targetFY,ab*lo);
        }
        vec3 result = mix(rgb,fullColor,amount);
        return vec4(result*source.a,source.a);
        """, helpers: PhotoExposureColor.kernel + """
        vec3 deepShadowLabRGB(float fy, vec2 ab) {
            vec3 xyz=vec3(0.9504559270516716*exposureLabInverse(fy+ab.x/500.0),
                exposureLabInverse(fy),1.0890577507598784*exposureLabInverse(fy-ab.y/200.0));
            return vec3(dot(xyz,vec3(3.240969941904521,-1.537383177570093,-0.498610760293)),
                dot(xyz,vec3(-0.9692436362808796,1.8759675015077202,0.04155505740717559)),
                dot(xyz,vec3(0.05563007969699366,-0.20397695888897652,1.0569715142428786)));
        }
        """)

    public static func apply(to image: CIImage, amount: Double, strength: Double = 1,
                             renderContext: CIContext? = nil) -> CIImage {
        let value = (amount.isFinite ? min(100,max(0,amount))/100 : 0)
            * (strength.isFinite ? min(1,max(0,strength)) : 0)
        let extent = image.extent
        guard value > 0, !extent.isEmpty, !extent.isInfinite,
              extent.minX.isFinite, extent.minY.isFinite,
              extent.maxX.isFinite, extent.maxY.isFinite,
              let guideKernel, let detailKernel, let adjustmentKernel, let colorGuideKernel,
              let linear = image.matchedFromWorkingSpace(to: space) else { return image }
        let width = PhotoDeepShadowLuminanceModel.width, height = PhotoDeepShadowLuminanceModel.height
        let scale = min(CGFloat(width)/extent.width,CGFloat(height)/extent.height)
        let padX = (CGFloat(width)-extent.width*scale)/2, padY = (CGFloat(height)-extent.height*scale)/2
        let transform = CGAffineTransform(a:scale,b:0,c:0,d:scale,
                                         tx:padX-extent.minX*scale,ty:padY-extent.minY*scale)
        let bounds = CGRect(x:0,y:0,width:width,height:height)
        // Filter before encoding so downsampling averages physical luminance.
        let small = linear.clampedToExtent().transformed(by:transform)
        guard let guide = guideKernel.apply(extent:bounds,arguments:[small]) else { return image }
        var input = [Float](repeating:0,count:width*height)
        input.withUnsafeMutableBytes {
            (renderContext ?? context).render(guide,toBitmap:$0.baseAddress!,rowBytes:width*4,
                                               bounds:bounds,format:.Rf,colorSpace:nil)
        }
        for i in input.indices { input[i] = input[i].isFinite ? min(1,max(0,input[i])) : 0 }
        guard let map = PhotoDeepShadowLuminanceModel.shared.coefficients(for:input),
              let detail = detailKernel.apply(extent:extent,arguments:[linear]) else { return image }
        // Suppress subpixel RAW noise before reintroducing luminance detail.
        // Scale to the image size so preview and full-resolution export agree.
        let radius = max(0.5, min(8, max(extent.width,extent.height)/1440*0.85))
        let cleanDetail = detail.clampedToExtent().applyingFilter("CIGaussianBlur",
            parameters:[kCIInputRadiusKey:radius]).cropped(to:extent)
        let colorRadius = radius*3.0
        guard let colorGuide = colorGuideKernel.apply(extent:extent,
                roiCallback:{ _, rect in rect.insetBy(dx:-2*colorRadius,dy:-2*colorRadius) },
                arguments:[linear.clampedToExtent(),colorRadius]),
              let result = adjustmentKernel.apply(extent:extent,arguments:[linear,cleanDetail,
                map.clampedToExtent().transformed(by:transform.inverted()),colorGuide,value]),
              let output = result.matchedToWorkingSpace(from:space) else { return image }
        return output.cropped(to:extent)
    }
}
