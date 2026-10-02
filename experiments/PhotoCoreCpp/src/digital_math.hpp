#pragma once
#include "film_internal.hpp"
namespace photocore::film_cpu {
// 與 Swift 的 D65 Lab 調整共用色域約束；保留亮度、色相及來源 HDR 範圍。
inline V lab_color_rgb(double fy, double a, double b) {
    auto inverse=[](double t){return t>6./29?t*t*t:(116*t-16)/(24389./27);};
    V xyz{.9504559270516716*inverse(fy+a/500),inverse(fy),1.0890577507598784*inverse(fy-b/200)};
    return {dot(xyz,{3.240969941904521,-1.537383177570093,-.498610760293}),
            dot(xyz,{-.9692436362808796,1.8759675015077202,.04155505740717559}),
            dot(xyz,{.05563007969699366,-.20397695888897652,1.0569715142428786})};
}
inline V lab_color(V rgb,double vibrance,double saturation) {
    if(dot(rgb,exact_w)<=0)return rgb;
    auto lab=rgb_to_lab({rgb.x,rgb.y,rgb.z});
    double fy=(lab[0]+16)/116, muted=1-smooth(0,100,std::hypot(lab[1],lab[2]));
    double gain=std::max(0.,1+saturation)*std::max(0.,1+vibrance*muted);
    double a=lab[1]*gain,b=lab[2]*gain;
    auto result=lab_color_rgb(fy,a,b);
    double lower=std::min({0.,rgb.x,rgb.y,rgb.z}),upper=std::max({1.,rgb.x,rgb.y,rgb.z});
    auto fits=[&](V v){return std::min({v.x,v.y,v.z})>=lower && std::max({v.x,v.y,v.z})<=upper;};
    if(!fits(result)) {
        double lo=0,hi=1;
        for(int i=0;i<12;++i){double mid=(lo+hi)*.5;if(fits(lab_color_rgb(fy,a*mid,b*mid)))lo=mid;else hi=mid;}
        result=lab_color_rgb(fy,a*lo,b*lo);
    }
    return result;
}
struct TonePoint { double x, y; };
inline double tone_slope(double a, double b) { return a > 0 && b > 0 ? 2 * a * b / (a + b) : 0; }
inline TonePoint tone_segment(double x, double y0, double y1, double m0, double m1) {
    double t=std::clamp(x,0.,1.),t2=t*t,t3=t2*t;
    return {(2*t3-3*t2+1)*y0+(t3-2*t2+t)*m0+(-2*t3+3*t2)*y1+(t3-t2)*m1,
        std::max(4*((6*t2-6*t)*y0+(3*t2-4*t+1)*m0+(-6*t2+6*t)*y1+(3*t2-2*t)*m1),0.)};
}
inline TonePoint hdr_point(double logValue, const std::array<double,5> &p) {
    double v=std::exp2(logValue);TonePoint result{};
    double d0=p[1]-p[0],d1=p[2]-p[1],d2=p[3]-p[2],d3=p[4]-p[3];
    double m1=tone_slope(d0,d1),m2=tone_slope(d1,d2),m3=tone_slope(d2,d3);
    if(v<=.25) result=tone_segment(v*4,p[0],p[1],d0,m1);
    else if(v<=.5) result=tone_segment((v-.25)*4,p[1],p[2],m1,m2);
    else if(v<=.75) result=tone_segment((v-.5)*4,p[2],p[3],m2,m3);
    else if(v<=1) result=tone_segment((v-.75)*4,p[3],p[4],m3,d3);
    else result={p[4]+v-1,1};
    double slope=result.x>1e-5?v*result.y/result.x:0;
    return {std::log2(std::max(result.x,1e-5)), slope>=0 && slope<1e20?slope:0};
}
inline double detail_segment(double t, TonePoint a, TonePoint b, double width) {
    double delta=std::max(b.x-a.x,0.),secant=delta/width;
    if(secant<1e-6) return a.x+(b.x-a.x)*t;
    double cross=t*(1-t);
    return a.x+delta*(secant*t*t+a.y*cross)/(secant+(a.y+b.y-2*secant)*cross);
}
inline TonePoint local_tone_point(double stops,double contrast,double highlights,double shadows) {
    auto slope=[](double lo,double hi,double x){double t=std::clamp((x-lo)/(hi-lo),0.,1.);return 6*t*(1-t)/(hi-lo);};
    double gain=1+contrast*.45,shadow=1-smooth(-2.3,.9,stops),protection=shadows<0?smooth(-5.5,-2.8,stops):1,highlight=smooth(.4,2.5,stops);
    return {stops*gain+shadows*.75*shadow*protection-highlights*.55*highlight,
        std::max(0.,gain+shadows*.75*(shadow*(shadows<0?slope(-5.5,-2.8,stops):0)-protection*slope(-2.3,.9,stops))-highlights*.55*slope(.4,2.5,stops))};
}
struct ToneSettings {
    std::array<double,5> points{};
    double amount, detail;
    explicit ToneSettings(const Json &a) {
        Json curve=a.value("hdrToneCurve",Json{});
        if(curve.is_null()) curve={{"black",0},{"shadows",38},{"midtones",50},{"highlights",64},{"white",100},{"detail",12}};
        double lower=0;int i=0;
        for (auto key:{"black","shadows","midtones","highlights","white"}) {lower=number(curve,key,0,lower,100);points[i++]=lower/100;}
        amount=number(a,"hdrAmount",0,0,100)/100;
        detail=1+number(curve,"detail",0,0,40)/40*.1;
    }
};
}
