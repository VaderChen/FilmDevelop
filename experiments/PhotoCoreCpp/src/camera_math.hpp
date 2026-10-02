#pragma once
#include "film_internal.hpp"
namespace photocore::film_cpu {
// Oklab 轉換：Björn Ottosson，public domain / MIT（https://bottosson.github.io/posts/oklab/）。
// 與 PhotoCameraProcessor 的 Oklab 相機模型保持相同階段；參數由 Swift 匯出。
inline V camera_to_lab(V c) {
    V lms=pow(max(V{dot(c,{.4122214708,.5363325363,.0514459929}),dot(c,{.2119034982,.6806995451,.1073969566}),dot(c,{.0883024619,.2817188376,.6299787005})},0),1./3);
    return {dot(lms,{.2104542553,.7936177850,-.0040720468}),dot(lms,{1.9779984951,-2.4285922050,.4505937099}),dot(lms,{.0259040371,.7827717662,-.8086757660})};
}
inline V camera_to_rgb(V c) {
    V lms{c.x+.3963377774*c.y+.2158037573*c.z,c.x-.1055613458*c.y-.0638541728*c.z,c.x-.0894841775*c.y-1.2914855480*c.z};lms=lms*lms*lms;
    return {dot(lms,{4.0767416621,-3.3077115913,.2309699292}),dot(lms,{-1.2684380046,2.6097574011,-.3413193965}),dot(lms,{-.0041960863,-.7034186147,1.7076147010})};
}
inline V camera_look(V rgb,const std::vector<float> &p) {
    rgb=clamp(rgb,0,1);V lab=camera_to_lab(rgb);
    auto curve=[&](double l){l=std::clamp(l,0.,1.);double upper=std::pow(l,p[0]),lower=std::pow(1-l,p[0]),pivot=std::pow(p[1]/(1-p[1]),p[0]-1);return p[2]+(p[3]-p[2])*upper/std::max(upper+lower*pivot,1e-12);};
    double sourceL=lab.x,L=curve(sourceL);
    if(p[18]>.5) {double value=curve(std::cbrt(dot(rgb,{.2126,.7152,.0722})));return V(value*value*value);}
    double chroma=std::hypot(lab.y,lab.z),hue=std::atan2(lab.z,lab.y),reliability=smooth(.015,.065,chroma);
    constexpr double pi=3.14159265358979323846;
    double centers[]{40,100,145,255},gain=0,angle=0;
    for(int i=0;i<4;++i){double weight=std::exp(9*(std::cos(hue-centers[i]*pi/180)-1))*reliability;gain+=weight*p[4+i];angle+=weight*p[8+i];}
    double warm=std::exp(8*(std::cos(hue-48*pi/180)-1))*smooth(.005,.030,chroma)*smooth(.10,.35,sourceL)*(1-smooth(.92,1,sourceL));
    double protection=1-p[19]*warm,saturation=std::max(0.,1+(p[17]-1+gain)*protection);angle*=protection;
    double a=(std::cos(angle)*lab.y-std::sin(angle)*lab.z)*saturation,b=(std::sin(angle)*lab.y+std::cos(angle)*lab.z)*saturation;
    double shadow=1-smooth(.20,.70,sourceL),highlight=smooth(.40,.90,sourceL),taper=smooth(0,.12,L)*(1-smooth(.88,1,L));
    a+=(p[12]*shadow+p[14]*highlight)*taper*protection;b+=(p[13]*shadow+p[15]*highlight)*taper*protection;
    auto fits=[](V c){return std::min({c.x,c.y,c.z})>=0 && std::max({c.x,c.y,c.z})<=1;};
    V result=camera_to_rgb({L,a,b});
    if(!fits(result)){double low=0,high=1;for(int i=0;i<14;++i){double mid=(low+high)*.5;if(fits(camera_to_rgb({L,a*mid,b*mid})))low=mid;else high=mid;}result=clamp(camera_to_rgb({L,a*low,b*low}),0,1);}
    return result;
}
}
