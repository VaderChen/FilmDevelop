#pragma once
#include "codec.hpp"
#include "vision.hpp"
#include <iomanip>
#include <numeric>
#include <sstream>
namespace filmdevelop {
// 與 Swift 相同的線性亮度統計；只提供模型參考，不覆寫使用者的調整。
inline Json analyze_photo(const photocore::Image &source,Codec &codec,const std::vector<FaceBox> &faces = {}) {
    auto preview=resized(source,800),sample=resized(preview,192);
    std::vector<double> luminances;
    for(const auto &pixel:sample.pixels) {
        if(!std::isfinite(pixel.a) || pixel.a<=24./255)continue;
        double r=std::max(0.,double(pixel.r)/pixel.a),g=std::max(0.,double(pixel.g)/pixel.a),b=std::max(0.,double(pixel.b)/pixel.a);
        if(std::isfinite(r)&&std::isfinite(g)&&std::isfinite(b))luminances.push_back(.2126*r+.7152*g+.0722*b);
    }
    std::string analysis;
    if(luminances.size()>32) {
        std::sort(luminances.begin(),luminances.end());
        auto percentile=[&](double p){double at=p*(luminances.size()-1);size_t low=size_t(at),high=std::min(low+1,luminances.size()-1);return luminances[low]+(luminances[high]-luminances[low])*(at-low);};
        double median=percentile(.5),p95=percentile(.95),mean=std::accumulate(luminances.begin(),luminances.end(),0.)/luminances.size();
        double ev=std::log2(.20/std::max(median,.015));
        if(mean<.12)ev=std::max(ev,std::log2(.16/std::max(mean,.015)));
        if(mean>.45)ev=std::min(ev,std::log2(.36/std::max(mean,.015)));
        if(ev>0 && p95>.72)ev=std::min(ev,std::log2(.94/std::max(p95,.015)));
        ev=std::clamp(ev,-1.2,1.2);if(std::abs(ev)<.12)ev=0;
        std::ostringstream text;text.imbue(std::locale::classic());text<<std::fixed<<std::setprecision(3);
        text<<"Measured input linear-light luminance (0=black, 1=white): median="<<median<<", mean="<<mean<<", p95="<<p95<<". A conservative whole-image exposure estimate is "<<ev<<" EV before style-strength attenuation. These measurements are advisory: distinguish intentional low-key scenes and protect bright backgrounds. They are not requested slider values.";
        if(!faces.empty()) {
            std::vector<double> medians;
            for(const auto &box:faces) {
                double dx=(box.right-box.left)*.15,dy=(box.bottom-box.top)*.15;
                int left=int(std::floor((box.left+dx)*preview.width)),right=int(std::ceil((box.right-dx)*preview.width)),top=int(std::floor((box.top+dy)*preview.height)),bottom=int(std::ceil((box.bottom-dy)*preview.height));
                std::vector<double> pixels;
                for(int y=top;y<bottom;++y)for(int x=left;x<right;++x){const auto p=preview.pixels[size_t(y)*preview.width+size_t(x)];if(p.a>24./255)pixels.push_back((.2126*std::max(p.r,0.f)+.7152*std::max(p.g,0.f)+.0722*std::max(p.b,0.f))/p.a);}
                if(pixels.size()>32){std::sort(pixels.begin(),pixels.end());size_t k=pixels.size()/2;medians.push_back(pixels.size()%2?pixels[k]:(pixels[k-1]+pixels[k])*.5);}
            }
            if(!medians.empty()) {
                text.str("");text.clear();text<<"Measured input linear-light luminance (0=black, 1=white): median="<<median<<", mean="<<mean<<", p95="<<p95<<". Detected face-region median luminances: ";
                for(size_t i=0;i<medians.size();++i){if(i)text<<", ";text<<medians[i];}
                text<<". The whole-image histogram may be dominated by the background; judge subject exposure separately. Face brightness is evidence, not a fixed skin-tone target. These measurements are advisory: distinguish intentional low-key scenes and protect bright backgrounds. They are not requested slider values.";
            }
        }
        analysis=text.str();
    }
    return {{"imageData",base64(codec.encode(preview,"jpeg",8,.88))},{"analysis",analysis}};
}
}
