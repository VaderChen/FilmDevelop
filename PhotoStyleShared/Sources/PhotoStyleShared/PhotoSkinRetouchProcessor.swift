import CoreImage

/// 柔膚專用的多尺度亮度處理；皮膚底色沿用來源 Lab a/b，不連帶修改降噪。
enum PhotoSkinRetouchProcessor {
    private static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let helpers = PhotoLabAdjustmentProcessor.helpers + """
    vec3 skinLuminance(vec3 rgb, float targetY) {
        float fy=exposureLabF(dot(rgb,vec3(0.21263900587151027,0.7151686787677559,0.07219231536073371)));
        float x=dot(rgb,vec3(0.41239079926595934,0.35758433938387796,0.1804807884018343));
        float z=dot(rgb,vec3(0.01933081871559185,0.11919477979462599,0.9505321522496607));
        vec2 ab=vec2(500.0*(exposureLabF(x/0.9504559270516716)-fy),
            200.0*(fy-exposureLabF(z/1.0890577507598784)));
        float targetF=exposureLabF(targetY);
        vec3 result=labColorRGB(targetF,ab);
        float lower=min(0.0,min(rgb.r,min(rgb.g,rgb.b)));
        float upper=max(1.0,max(rgb.r,max(rgb.g,rgb.b)));
        if(min(result.r,min(result.g,result.b))<lower || max(result.r,max(result.g,result.b))>upper) {
            float lo=0.0,hi=1.0;
            for(int i=0;i<16;++i) {
                float mid=(lo+hi)*0.5;
                vec3 candidate=labColorRGB(targetF,ab*mid);
                if(min(candidate.r,min(candidate.g,candidate.b))>=lower && max(candidate.r,max(candidate.g,candidate.b))<=upper) lo=mid;
                else hi=mid;
            }
            result=labColorRGB(targetF,ab*lo);
        }
        return result;
    }
    """

    private static let whiteningKernel = PhotoGPUColorKernel.make("naturalSkinWhitening",
        parameters: "__sample source, __sample mask, float amount", body: """
        float weight=clamp(mask.r,0.0,1.0)*0.68*amount;
        if(source.a<=0.0 || weight<=0.0) return source;
        vec3 rgb=source.rgb/source.a;
        float y=dot(rgb,vec3(0.21263900587151027,0.7151686787677559,0.07219231536073371));
        if(y<=0.0 || y>=1.0) return source;
        float lightness=(116.0*exposureLabF(y)-16.0)/100.0;
        // 提亮幅度增加 25%；k 至多 1.02，最小斜率仍為 0.66，黑白端點固定。
        float target=lightness+1.5*weight*lightness*(1.0-lightness)*(1.0-lightness);
        float targetY=exposureLabInverse((100.0*target+16.0)/116.0);
        return vec4(skinLuminance(rgb,targetY)*source.a,source.a);
        """, helpers: helpers)

    private static let statisticsKernel = PhotoGPUColorKernel.make("skinLogStatistics",
        parameters: "__sample source, __sample mask", body: """
        if(source.a<=0.0) return vec4(0.0);
        float y=max(0.0,dot(source.rgb/source.a,vec3(0.21263900587151027,0.7151686787677559,0.07219231536073371)));
        float value=log2(y+0.00001), weight=source.a*clamp(mask.r,0.0,1.0);
        return vec4(value*weight,value*value*weight,0.0,weight);
        """)

    private static let smoothingKernel = PhotoGPUColorKernel.make("naturalSkinSmoothing",
        parameters: "__sample source, __sample fine, __sample coarse, __sample mask, float amount, float epsilon", body: """
        float weight=clamp(mask.r,0.0,1.0)*amount;
        if(source.a<=0.0 || weight<=0.0 || fine.a<=0.00000001 || coarse.a<=0.00000001) return source;
        vec3 rgb=source.rgb/source.a;
        float y=dot(rgb,vec3(0.21263900587151027,0.7151686787677559,0.07219231536073371));
        if(y<=0.0) return source;
        float value=log2(y+0.00001), mf=fine.r/fine.a, mc=coarse.r/coarse.a;
        float vf=max(0.0,fine.g/fine.a-mf*mf), vc=max(0.0,coarse.g/coarse.a-mc*mc);
        float fineDelta=(mf-value)*epsilon/(vf+epsilon);
        float coarseDelta=(mc-value)*epsilon/(vc+epsilon);
        // 多尺度差異保留微紋理；高頻只允許有限減弱，不將其一律視為雜訊。
        float attenuation=0.12+0.23*smoothstep(0.35,0.85,vf/max(vc,0.000001));
        float delta=coarseDelta-(1.0-attenuation)*fineDelta;
        // 只朝局部底層靠近，避免殘差重建造成反向銳化與邊界光暈。
        delta=clamp(delta,min(0.0,mc-value),max(0.0,mc-value));
        float protection=1.0-smoothstep(0.025,0.12,vc);
        delta*=weight*protection;
        if(abs(delta)<0.0000001) return source;
        float targetY=max(0.0,exp2(value+delta)-0.00001);
        return vec4(skinLuminance(rgb,targetY)*source.a,source.a);
        """, helpers: helpers)

    static func whiten(_ image: CIImage, mask: CIImage, amount: Double) -> CIImage {
        guard let linear = image.matchedFromWorkingSpace(to: space), let whiteningKernel,
              let output = whiteningKernel.apply(extent: image.extent, arguments: [linear, mask, amount]) else { return image }
        return output.matchedToWorkingSpace(from: space) ?? image
    }

    static func smooth(_ image: CIImage, mask: CIImage, radius: Double, amount: Double) -> CIImage {
        guard let linear = image.matchedFromWorkingSpace(to: space), let statisticsKernel, let smoothingKernel,
              let statistics = statisticsKernel.apply(extent: image.extent, arguments: [linear, mask]) else { return image }
        // 只需兩張加權統計圖，無需多份 RGB 平滑圖或 CPU 讀回。
        let sampled = statistics.insertingIntermediate(cache: false)
        let fine = PhotoBoxMeanFilter.apply(sampled, radius: max(1, min(64, (radius * 0.35).rounded())))
        let coarse = PhotoBoxMeanFilter.apply(sampled, radius: max(2, min(64, (radius * 3).rounded())))
        // 強度連續增加至滿值，不提前封頂；紋理與結構保護維持原式。
        guard let output = smoothingKernel.apply(extent: image.extent,
            arguments: [linear, fine, coarse, mask, amount * 0.78, 0.002 + amount * 0.018]) else { return image }
        return output.matchedToWorkingSpace(from: space) ?? image
    }
}
