// 由 PhotoCameraProcessor 的 Oklab 核心移植；配方參數維持單一來源。
vec3 grToLab(vec3 c) {
    vec3 lms = vec3(dot(c,vec3(.4122214708,.5363325363,.0514459929)),
                        dot(c,vec3(.2119034982,.6806995451,.1073969566)),
                        dot(c,vec3(.0883024619,.2817188376,.6299787005)));
    lms = pow(max(lms,0.0f),vec3(1.0f/3.0f));
    return vec3(dot(lms,vec3(.2104542553,.7936177850,-.0040720468)),
                  dot(lms,vec3(1.9779984951,-2.4285922050,.4505937099)),
                  dot(lms,vec3(.0259040371,.7827717662,-.8086757660)));
}
vec3 grToRGB(vec3 c) {
    vec3 lms = vec3(c.x + .3963377774*c.y + .2158037573*c.z,
                       c.x - .1055613458*c.y - .0638541728*c.z,
                       c.x - .0894841775*c.y - 1.2914855480*c.z);
    lms = lms*lms*lms;
    return vec3(dot(lms,vec3(4.0767416621,-3.3077115913,.2309699292)),
                  dot(lms,vec3(-1.2684380046,2.6097574011,-.3413193965)),
                  dot(lms,vec3(-.0041960863,-.7034186147,1.7076147010)));
}
bool grInGamut(vec3 c) { return all(greaterThanEqual(c,vec3(0))) && all(lessThanEqual(c,vec3(1))); }

// 固定明度與色相，只縮彩度；避免逐通道硬裁切造成亮部變色。
vec3 grGamut(vec3 lab) {
    vec3 rgb=grToRGB(lab);
    if (grInGamut(rgb)) return rgb;
    float low=0.0f, high=1.0f;
    for (int i=0;i<14;++i) {
        float mid=(low+high)*0.5f;
        if (grInGamut(grToRGB(vec3(lab.x,lab.yz*mid)))) low=mid; else high=mid;
    }
    return clamp(grToRGB(vec3(lab.x,lab.yz*low)),0.0f,1.0f);
}
float grCurve(float L, vec4 tone) {
    L=clamp(L,0.0f,1.0f);
    float upper=pow(L,tone.x), lower=pow(1.0f-L,tone.x);
    float pivot=pow(tone.y/(1.0f-tone.y),tone.x-1.0f);
    return mix(tone.z,tone.w,upper/max(upper+lower*pivot,1e-12f));
}
vec3 cameraLook(vec3 rgb) {
 rgb=clamp(rgb,0,1);
 vec4 tone=vec4(p[0],p[1],p[2],p[3]),hueGain=vec4(p[4],p[5],p[6],p[7]),hueShift=vec4(p[8],p[9],p[10],p[11]),split=vec4(p[12],p[13],p[14],p[15]),controls=vec4(p[16],p[17],p[18],p[19]);
    vec3 lab=grToLab(rgb);
    float sourceL=lab.x;
    float L=grCurve(sourceL,tone);
    vec3 base=rgb, result;
    if (controls.z>0.5f) {
        // 中性灰階用線性亮度；強度只調反差，避免 50% 變成半彩色。
        float luminance=dot(rgb,vec3(.2126,.7152,.0722));
        base=vec3(luminance);
        float monoL=grCurve(pow(luminance,1.0f/3.0f),tone);
        result=vec3(monoL*monoL*monoL);
    } else {
        float chroma=length(lab.yz), hue=atan(lab.z,lab.y);
        float hueReliability=smoothstep(.015f,.065f,chroma);
        vec4 centres=vec4(40.0f,100.0f,145.0f,255.0f)*3.14159265358979323846/180.0f;
        // 週期連續的色相權重，無區間接縫；近中性像素不旋轉色相。
        vec4 weights=exp(9.0f*(cos(hue-centres)-1.0f))*hueReliability;
        float warm=exp(8.0f*(cos(hue-48.0f*3.14159265358979323846/180.0f)-1.0f))*smoothstep(.005f,.030f,chroma);
        warm*=smoothstep(.10f,.35f,sourceL)*(1.0f-smoothstep(.92f,1.0f,sourceL));
        float protection=1.0f-controls.w*warm;
        float saturation=1.0f+(controls.y-1.0f+dot(weights,hueGain))*protection;
        float angle=dot(weights,hueShift)*protection;
        float cs=cos(angle), sn=sin(angle);
        vec2 ab=vec2(cs*lab.y-sn*lab.z,sn*lab.y+cs*lab.z)*max(saturation,0.0f);
        float shadow=1.0f-smoothstep(.20f,.70f,sourceL);
        float highlight=smoothstep(.40f,.90f,sourceL);
        float taper=smoothstep(0.0f,.12f,L)*(1.0f-smoothstep(.88f,1.0f,L));
        ab+=(split.xy*shadow+split.zw*highlight)*taper*protection;
        result=grGamut(vec3(L,ab));
    }
 return result;
}
